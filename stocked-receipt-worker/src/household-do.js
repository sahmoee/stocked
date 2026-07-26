// household-do.js — HouseholdDO Durable Object (improvement #1).
//
// WHY: the old flow was KV get → merge → put on ONE key. KV is eventually
// consistent and last-write-wins, so two devices pushing at the same moment
// could clobber each other. A Durable Object instance is single-threaded and
// its storage is transactional, so every action on a given household code is
// SERIALIZED — the read-modify-write can no longer race. One DO per code
// (addressed by idFromName(code)). KV is kept only as a cheap snapshot mirror.
//
// The app-facing request/response shapes are IDENTICAL to the previous handler,
// so the shipped iOS client needs no changes.

import {
  HH_MAX_ITEMS, ROLE_DEFAULTS, sanitizeName, sanitizeId, appendActivity,
  mergeLWW, dedupeCap, semanticHousehold, FEATURE_COLLECTIONS,
  pushBatchHash, PUSH_DEDUPE_WINDOW_MS, PUSH_DEDUPE_MAX,
} from "./household-shared.js";

const DOC = "doc";
const PRESENCE = "presence";
const RECENT_PUSHES = "recentPushes";

export class HouseholdDO {
  constructor(state, env) {
    this.state = state;
    this.storage = state.storage;
    this.env = env;
  }

  async fetch(request) {
    let msg;
    try { msg = await request.json(); } catch { return this.json({ error: "Invalid JSON" }, 400); }
    const action = msg.action;
    const body = msg.body || {};
    try {
      // Lazy migration: households created by the OLD KV-backed worker live in KV under
      // "hh:<code>" but the DO's own storage starts empty, so pull/push would 404
      // ("share not found"). On first touch, seed the DO from the KV snapshot so existing
      // households keep working seamlessly after the Durable Object cutover.
      // msg.code is the normalized code (matches the KV key); fall back to body.code.
      await this.ensureSeeded(msg.code || body.code);
      switch (action) {
        case "create":    return await this.create(body);
        case "exists":    return await this.exists();
        case "import":    return await this.importDoc(body);
        case "destroy":   return await this.destroy();
        case "join":      return await this.join(body);
        case "pull":      return await this.pull(body);
        case "presence":  return await this.presence(body);
        case "push":      return await this.push(body);
        case "setrole":   return await this.setrole(body);
        case "setname":   return await this.setname(body);
        case "leave":     return await this.leave(body);
        default:          return this.json({ error: "Unknown household action" }, 404);
      }
    } catch (e) {
      return this.json({ error: "household DO threw: " + String((e && e.message) || e), code: "householdCrash" }, 500);
    }
  }

  // ── storage helpers ────────────────────────────────────────────────────────
  /** One-time seed of this DO from the legacy KV snapshot if its storage is empty. */
  async ensureSeeded(code) {
    if (!code || !this.env.RATE_KV) return;
    if (await this.storage.get(DOC)) return;        // already have DO-native state
    try {
      const raw = await this.env.RATE_KV.get("hh:" + String(code));
      if (raw) {
        const doc = JSON.parse(raw);
        if (doc && doc.code) await this.storage.put(DOC, doc);
      }
    } catch { /* seeding is best-effort; a fresh household just starts empty */ }
  }

  async getDoc() { return (await this.storage.get(DOC)) || null; }
  async putDoc(doc) {
    await this.storage.put(DOC, doc);
    // Best-effort KV snapshot mirror for cheap reads/backup. Never blocks correctness.
    try { if (this.env.RATE_KV && doc && doc.code) await this.env.RATE_KV.put("hh:" + doc.code, JSON.stringify(doc), { expirationTtl: 31536000 }); } catch {}
  }
  json(obj, status = 200) {
    return new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
  }

  /** Bump revision + updatedAt only when the semantic content actually changed. */
  async commit(prev, next) {
    if (prev && JSON.stringify(semanticHousehold(prev)) === JSON.stringify(semanticHousehold(next))) {
      next.updatedAt = prev.updatedAt || 0;
      next.revision = prev.revision || 0;
      await this.putDoc(next);
      return false;
    }
    next.updatedAt = Date.now();
    next.revision = Number((prev && prev.revision) || 0) + 1;
    await this.putDoc(next);
    return true;
  }

  // ── actions ─────────────────────────────────────────────────────────────────
  async exists() { return this.json({ exists: !!(await this.getDoc()) }); }

  async create(body) {
    if (await this.getDoc()) return this.json({ taken: true }, 409); // code collision → caller retries
    const ownerName = sanitizeName(body.ownerName);
    const ownerId = sanitizeId(body.memberId);
    const household = {
      code: body.code, ownerName, ownerId,
      members: [{ name: ownerName, memberId: ownerId, joinedAt: Date.now() }],
      inventory: [], grocery: [], userRecipes: [], genRecipes: [], plannedMeals: [],
      activity: [{ kind: "householdCreated", itemName: "", actorName: ownerName, date: Date.now() }],
      updatedAt: Date.now(), revision: 1,
    };
    // 1.4 — seed the feature collections so pulls always find arrays, never undefined.
    for (const key of FEATURE_COLLECTIONS) household[key] = [];
    await this.putDoc(household);
    return this.json({ code: household.code, household });
  }

  async importDoc(body) {
    // Used by regenerate: initialize this DO with an existing doc under a new code.
    const doc = body.household;
    if (!doc) return this.json({ error: "no doc" }, 400);
    doc.code = body.code;
    doc.updatedAt = Date.now();
    doc.revision = 1;
    await this.putDoc(doc);
    return this.json({ code: doc.code, household: doc });
  }

  async destroy() {
    const doc = await this.getDoc();
    try { if (this.env.RATE_KV && doc && doc.code) await this.env.RATE_KV.delete("hh:" + doc.code); } catch {}
    await this.storage.deleteAll();
    return this.json({ ok: true });
  }

  async join(body) {
    const household = await this.getDoc();
    if (!household) return this.json({ error: "share not found", code: "notFound" }, 404);
    const memberName = sanitizeName(body.memberName);
    const memberId = sanitizeId(body.memberId);
    const idx = household.members.findIndex((m) => memberId ? m.memberId === memberId : (m.name === memberName && !m.memberId));
    if (idx === -1) {
      household.members.push({ name: memberName, memberId, joinedAt: Date.now() });
      household.activity = appendActivity(household.activity, { kind: "memberJoined", itemName: "", actorName: memberName, date: Date.now() });
      await this.commit(household, household);
    } else if (household.members[idx].name !== memberName || !household.members[idx].memberId) {
      household.members[idx].name = memberName;
      household.members[idx].memberId = memberId || household.members[idx].memberId;
      await this.commit({ ...household, _force: 1 }, household); // ensure updatedAt bumps for a real change
    }
    return this.json({ ok: true, household });
  }

  async pull(body) {
    const household = await this.getDoc();
    if (!household) return this.json({ error: "share not found", code: "notFound" }, 404);
    const mid = sanitizeId(body.memberId);
    if (mid) {
      const presence = (await this.storage.get(PRESENCE)) || {};
      presence[mid] = { name: sanitizeName(body.memberName), ts: Date.now() };
      await this.storage.put(PRESENCE, presence);
    }
    const since = Number(body.since || 0);
    const sinceRevision = Number(body.sinceRevision || 0);
    const unchangedByRevision = sinceRevision > 0 && Number(household.revision || 0) <= sinceRevision;
    const unchangedByTime = sinceRevision <= 0 && since > 0 && Number(household.updatedAt || 0) <= since;
    if (unchangedByRevision || unchangedByTime) {
      return this.json({ unchanged: true, updatedAt: household.updatedAt || 0, revision: household.revision || 0 });
    }
    return this.json({ household });
  }

  async presence(_body) {
    const household = await this.getDoc();
    if (!household) return this.json({ error: "share not found", code: "notFound" }, 404);
    return this.json({ presence: (await this.storage.get(PRESENCE)) || {} });
  }

  async push(body) {
    const household = await this.getDoc();
    if (!household) return this.json({ error: "share not found", code: "notFound" }, 404);

    // Idempotency (safe retries): the push payload has no batch id, so dedupe on
    // a hash of the batch content + sender within a rolling window. A batch that
    // was already applied is skipped and answered with the same success shape.
    const batchHash = pushBatchHash(body);
    const now = Date.now();
    let recent = (await this.storage.get(RECENT_PUSHES)) || [];
    if (!Array.isArray(recent)) recent = [];
    recent = recent.filter((e) => e && now - Number(e.ts || 0) < PUSH_DEDUPE_WINDOW_MS).slice(-PUSH_DEDUPE_MAX);
    if (batchHash && recent.some((e) => e.h === batchHash)) {
      return this.json({ ok: true, changed: false, household, deduped: true });
    }

    // Permission enforcement (unchanged semantics).
    const actorId = sanitizeId(body.actorId);
    const isOwner = actorId && actorId === household.ownerId;
    let canWrite = true, canRemove = true;
    if (!isOwner) {
      const me = (household.members || []).find((m) => m.memberId === actorId);
      if (me) {
        const def = ROLE_DEFAULTS[me.role] || ROLE_DEFAULTS.adult;
        const add  = (typeof me.overrideCanAdd    === "boolean") ? me.overrideCanAdd    : def.add;
        const edit = (typeof me.overrideCanEdit   === "boolean") ? me.overrideCanEdit   : def.edit;
        canRemove  = (typeof me.overrideCanRemove === "boolean") ? me.overrideCanRemove : def.remove;
        canWrite = add || edit;
      }
    }
    if (!canWrite) return this.json({ error: "Your access level can't change the household pantry", code: "forbidden" }, 403);
    if (!canRemove) { body.invDeleted = []; body.groDeleted = []; body.userRecipeDeleted = []; body.genRecipeDeleted = []; }

    household.invDeleted = dedupeCap((household.invDeleted || []).concat(Array.isArray(body.invDeleted) ? body.invDeleted : []), HH_MAX_ITEMS);
    household.groDeleted = dedupeCap((household.groDeleted || []).concat(Array.isArray(body.groDeleted) ? body.groDeleted : []), HH_MAX_ITEMS);
    household.userRecipeDeleted = dedupeCap((household.userRecipeDeleted || []).concat(Array.isArray(body.userRecipeDeleted) ? body.userRecipeDeleted : []), HH_MAX_ITEMS);
    household.genRecipeDeleted = dedupeCap((household.genRecipeDeleted || []).concat(Array.isArray(body.genRecipeDeleted) ? body.genRecipeDeleted : []), HH_MAX_ITEMS);
    household.mealDeleted = dedupeCap((household.mealDeleted || []).concat(Array.isArray(body.mealDeleted) ? body.mealDeleted : []), HH_MAX_ITEMS);
    const invDel = new Set(household.invDeleted);
    const groDel = new Set(household.groDeleted);
    const userRecipeDel = new Set(household.userRecipeDeleted);
    const genRecipeDel = new Set(household.genRecipeDeleted);
    const mealDel = new Set(household.mealDeleted);

    if (Array.isArray(body.inventory)) household.inventory = mergeLWW(household.inventory, body.inventory, invDel).slice(0, HH_MAX_ITEMS);
    if (Array.isArray(body.grocery)) household.grocery = mergeLWW(household.grocery, body.grocery, groDel).slice(0, HH_MAX_ITEMS);
    if (Array.isArray(body.userRecipes)) household.userRecipes = mergeLWW(household.userRecipes, body.userRecipes, userRecipeDel).slice(0, HH_MAX_ITEMS);
    if (Array.isArray(body.genRecipes)) household.genRecipes = mergeLWW(household.genRecipes, body.genRecipes, genRecipeDel).slice(0, HH_MAX_ITEMS);
    if (Array.isArray(body.plannedMeals)) household.plannedMeals = mergeLWW(household.plannedMeals, body.plannedMeals, mealDel).slice(0, HH_MAX_ITEMS);
    if (Array.isArray(body.activity)) household.activity = appendActivity((household.activity || []).concat(body.activity), null);

    // Launch readiness 1.4 — the client's feature collections (leftovers, family profiles,
    // events, shared costs, store layouts, garden harvests, container labels, takeout log).
    // Same per-item LWW as inventory: mergeLWW keys by `id` and resolves ties by
    // updatedAt/lastWriterID, treating the rest of the item body opaquely — so client-side
    // model changes never need a Worker change again. Store layouts are the one exception:
    // they have no UUID (keyed by store name), so they get a dedicated name-keyed merge where
    // MORE TRIPS wins — losing learned trips hurts more than losing recency.
    for (const key of FEATURE_COLLECTIONS) {
      const delKey = key + "Deleted";
      if (!canRemove) body[delKey] = [];
      household[delKey] = dedupeCap((household[delKey] || []).concat(Array.isArray(body[delKey]) ? body[delKey] : []), HH_MAX_ITEMS);
      const del = new Set(household[delKey]);
      if (Array.isArray(body[key])) {
        if (key === "storeLayouts") {
          // Name-keyed merge: more trips wins (learned data), then updatedAt.
          const byName = new Map();
          for (const l of household[key] || []) {
            const k = String(l.store || "").toLowerCase();
            if (k && !del.has(k)) byName.set(k, l);
          }
          for (const l of body[key]) {
            const k = String(l.store || "").toLowerCase();
            if (!k || del.has(k)) continue;
            const cur = byName.get(k);
            if (!cur || Number(l.trips || 0) > Number(cur.trips || 0)
                || (Number(l.trips || 0) === Number(cur.trips || 0) && Number(l.updatedAt || 0) >= Number(cur.updatedAt || 0))) {
              byName.set(k, l);
            }
          }
          household[key] = Array.from(byName.values()).slice(0, HH_MAX_ITEMS);
        } else {
          household[key] = mergeLWW(household[key] || [], body[key], del).slice(0, HH_MAX_ITEMS);
        }
      }
    }

    // #3 — shared household name (last writer among members who set one wins).
    if (typeof body.householdName === "string" && body.householdName.trim()) {
      household.name = body.householdName.trim().slice(0, 60);
    }
    // Hidden QA Workbook blob — last-writer-wins by updatedAt.
    if (body.qa && typeof body.qa === "object") {
      const inTs = Number(body.qa.updatedAt || 0);
      const curTs = Number((household.qa && household.qa.updatedAt) || 0);
      if (inTs >= curTs) household.qa = body.qa;
    }

    const changed = await this.commit({ ...household }, household);
    if (batchHash) {
      recent.push({ h: batchHash, ts: now });
      await this.storage.put(RECENT_PUSHES, recent.slice(-PUSH_DEDUPE_MAX));
    }
    return this.json({ ok: true, changed, household });
  }

  async setrole(body) {
    const household = await this.getDoc();
    if (!household) return this.json({ error: "share not found", code: "notFound" }, 404);
    const actorId = sanitizeId(body.actorId);
    if (!actorId || actorId !== household.ownerId) return this.json({ error: "Only the household owner can change member levels", code: "forbidden" }, 403);
    const targetId = sanitizeId(body.memberId);
    const role = typeof body.role === "string" ? body.role.slice(0, 20) : "";
    const label = typeof body.label === "string" ? body.label.slice(0, 40) : undefined;
    const idx = household.members.findIndex((m) => m.memberId === targetId);
    if (idx === -1) return this.json({ error: "member not found", code: "notFound" }, 404);
    if (targetId !== household.ownerId && role) household.members[idx].role = role;
    if (label !== undefined) household.members[idx].label = label;
    for (const key of ["overrideCanAdd", "overrideCanEdit", "overrideCanRemove"]) {
      if (key in body) {
        if (body[key] === null) delete household.members[idx][key];
        else if (typeof body[key] === "boolean") household.members[idx][key] = body[key];
      }
    }
    await this.commit({ ...household, _f: 1 }, household);
    return this.json({ ok: true, household });
  }

  async setname(body) {
    const household = await this.getDoc();
    if (!household) return this.json({ error: "share not found", code: "notFound" }, 404);
    const actorId = sanitizeId(body.actorId || body.memberId);
    const newName = sanitizeName(body.name);
    if (!actorId || !newName) return this.json({ error: "Missing member or name", code: "badRequest" }, 400);
    const idx = (household.members || []).findIndex((m) => m.memberId === actorId);
    if (idx === -1) return this.json({ error: "member not found", code: "notFound" }, 404);
    const oldName = household.members[idx].name || "";
    if (oldName === newName) return this.json({ ok: true, household });
    household.members[idx].name = newName;
    if (actorId === household.ownerId) household.ownerName = newName;
    const evt = { kind: "memberRenamed", itemName: newName, oldName, actorName: oldName || newName, date: Date.now() };
    household.activity = appendActivity((household.activity || []).concat([evt]), null);
    await this.commit({ ...household, _f: 1 }, household);
    return this.json({ ok: true, household });
  }

  async leave(body) {
    const household = await this.getDoc();
    if (!household) return this.json({ ok: true });
    const memberName = sanitizeName(body.memberName);
    const memberId = sanitizeId(body.memberId);
    household.members = household.members.filter((m) => memberId ? m.memberId !== memberId : m.name !== memberName);
    household.activity = appendActivity(household.activity, { kind: "memberLeft", itemName: "", actorName: memberName, date: Date.now() });
    if (household.members.length === 0) {
      await this.destroy();
    } else {
      await this.commit({ ...household, _f: 1 }, household);
    }
    return this.json({ ok: true });
  }
}
