// dailybrief.js — household daily brief (new function #10).
//
// Generation is deterministic assembly (expiring food, plan gaps, grocery
// reminders, leftovers, recent adds, one recommended action). Delivery/scheduling
// go through Queues + Cron rather than being rebuilt at app launch. Queues give
// batching, retries, delays, and dead-letter handling.

import { json, errJson, readBoundedJSON, background, logEvent } from "./util.js";
import { validateDailyBrief, BRIEF_MAX_BYTES } from "./validation.js";

/** Pure brief assembly from a context payload the app (or a stored snapshot) provides. */
export function buildBrief(ctx) {
  const now = Date.now();
  const inv = Array.isArray(ctx.inventory) ? ctx.inventory : [];
  const planned = Array.isArray(ctx.plannedMeals) ? ctx.plannedMeals : [];
  const grocery = Array.isArray(ctx.grocery) ? ctx.grocery : [];

  const expiring = inv
    .filter((i) => Number.isFinite(i.daysUntilExpiry) && i.daysUntilExpiry <= 3)
    .sort((a, b) => a.daysUntilExpiry - b.daysUntilExpiry)
    .slice(0, 8)
    .map((i) => ({ name: i.name, days: i.daysUntilExpiry }));

  const leftovers = inv.filter((i) => /leftover|cooked /i.test(i.name || "")).slice(0, 5).map((i) => i.name);
  const recentlyAdded = inv.filter((i) => Number.isFinite(i.addedAt) && now - i.addedAt < 86400000).slice(0, 5).map((i) => i.name);
  const groceryToBuy = grocery.filter((g) => !g.isChecked).length;
  const planGaps = Math.max(0, (Number(ctx.planHorizonDays) || 0) - planned.length);

  // One recommended action, prioritized.
  let action = "You're in good shape — nothing urgent today.";
  if (expiring.length) action = `Use ${expiring[0].name} soon — ${expiring[0].days <= 0 ? "it's due today" : `${expiring[0].days} day(s) left`}.`;
  else if (planGaps > 0) action = `You have ${planGaps} open dinner slot(s) this week — plan one now.`;
  else if (groceryToBuy > 0) action = `${groceryToBuy} item(s) on your grocery list are unchecked.`;

  return {
    schemaVersion: 1,
    generatedAt: now,
    expiring, leftovers, recentlyAdded,
    grocery: { toBuy: groceryToBuy },
    planGaps,
    recommendedAction: action,
  };
}

/** POST /daily-brief/generate → synchronous brief (used on demand). */
export async function handleDailyBrief(request, env, ctx, requestId) {
  const read = await readBoundedJSON(request, BRIEF_MAX_BYTES);
  if (!read.ok && read.status === 413) return errJson(413, "Payload too large", { code: "payloadTooLarge", requestId });
  const body = read.ok ? (read.value || {}) : {};      // invalid JSON keeps its lenient legacy behavior ({} → empty brief)
  const v = validateDailyBrief(body);
  if (!v.ok) return errJson(422, "Validation failed", { code: "invalidInput", requestId, extra: { errors: v.errors } });
  const brief = buildBrief(body);
  // Persist the latest brief per household for cheap re-reads (best-effort).
  if (env.RATE_KV && body.code) background(ctx, env.RATE_KV.put("brief:" + body.code, JSON.stringify(brief), { expirationTtl: 172800 }));
  return json(brief);
}

/** Producer: enqueue a brief job (used by the scheduled handler). */
export async function enqueueBrief(env, payload) {
  if (!env.BRIEF_QUEUE) return false;
  await env.BRIEF_QUEUE.send(payload);
  return true;
}

/** Consumer: process a batch of queued brief jobs (Queues handler). */
export async function handleBriefQueue(batch, env, _ctx) {
  for (const msg of batch.messages) {
    try {
      const payload = msg.body || {};
      const brief = buildBrief(payload.context || {});
      if (env.RATE_KV && payload.code) await env.RATE_KV.put("brief:" + payload.code, JSON.stringify(brief), { expirationTtl: 172800 });
      logEvent({ event: "briefGenerated", code: payload.code || null });
      msg.ack();
    } catch (e) {
      logEvent({ event: "briefQueueError", error: String((e && e.message) || e) });
      msg.retry(); // Queues will redeliver, then dead-letter after max attempts
    }
  }
}

/** Cron: enqueue brief generation for households with a stored snapshot. */
export async function handleScheduledBriefs(_event, env, _ctx) {
  if (!env.RATE_KV || !env.BRIEF_QUEUE) { logEvent({ event: "cronSkip", reason: "missing binding" }); return; }
  // Households opt in by storing a "briefctx:<code>" snapshot; we enqueue each.
  const list = await env.RATE_KV.list({ prefix: "briefctx:" });
  for (const k of list.keys) {
    const code = k.name.replace(/^briefctx:/, "");
    const raw = await env.RATE_KV.get(k.name);
    let context = {}; try { context = raw ? JSON.parse(raw) : {}; } catch {}
    await enqueueBrief(env, { code, context });
  }
  logEvent({ event: "cronEnqueued", count: list.keys.length });
}
