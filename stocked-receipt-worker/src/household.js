// household.js — Worker-side forwarder to the HouseholdDO.
//
// Translates the app's /household/<action> POSTs into DO calls. One DO per code
// (idFromName(code)). Preserves every request/response shape. Code allocation and
// regenerate (which moves a doc between codes) are orchestrated here because they
// span two DO instances.

import { makeHouseholdCode, json, errJson, readBoundedJSON, codeForStatus } from "./util.js";
import { normalizeCode } from "./household-shared.js";

const MAX_BODY = 2 * 1024 * 1024;   // household docs can be large; still bounded

function stub(env, code) {
  const id = env.HOUSEHOLD_DO.idFromName(code);
  return env.HOUSEHOLD_DO.get(id);
}

async function callDO(env, code, action, body) {
  const res = await stub(env, code).fetch("https://do.internal/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    // `code` here is already normalized (matches the DO id + KV "hh:" key), so the DO can
    // seed itself from the legacy KV snapshot using the correct key.
    body: JSON.stringify({ action, code, body }),
  });
  const text = await res.text();
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = { error: "DO returned non-JSON" }; }
  return { status: res.status, body: parsed };
}

/** Non-2xx bodies leave here with the consistent { error, code, requestId } envelope. */
function reply(r, requestId) {
  if (r.status >= 400 && r.body && typeof r.body === "object") {
    if (!r.body.code) r.body.code = codeForStatus(r.status);
    if (requestId && !r.body.requestId) r.body.requestId = requestId;
  }
  return json(r.body, r.status);
}

export async function handleHousehold(pathname, request, env, requestId) {
  const read = await readBoundedJSON(request, MAX_BODY);
  if (!read.ok) return errJson(read.status, read.message || "Bad request", { code: read.code, requestId });
  const body = read.value;
  const action = pathname.replace(/^\/household\/?/, "");

  // create: allocate an unused code, then init that DO.
  if (action === "create") {
    for (let attempt = 0; attempt < 8; attempt++) {
      const code = makeHouseholdCode();
      const r = await callDO(env, code, "create", { ...body, code });
      if (r.status === 409) continue; // collision, try another code
      return reply(r, requestId);
    }
    return errJson(503, "Could not allocate a code, try again", { code: "unavailable", requestId });
  }

  // regenerate: read old doc, init a fresh code's DO with it, destroy the old.
  if (action === "regenerate") {
    const oldCode = normalizeCode(body.code);
    const pulled = await callDO(env, oldCode, "pull", { code: oldCode });
    if (pulled.status === 404 || !pulled.body.household) return errJson(404, "share not found", { code: "notFound", requestId });
    for (let attempt = 0; attempt < 8; attempt++) {
      const newCode = makeHouseholdCode();
      if (newCode === oldCode) continue;
      const exists = await callDO(env, newCode, "exists", {});
      if (exists.body && exists.body.exists) continue;
      const imported = await callDO(env, newCode, "import", { code: newCode, household: pulled.body.household });
      if (imported.status >= 400) continue;
      await callDO(env, oldCode, "destroy", {});
      return reply(imported, requestId);
    }
    return errJson(503, "Could not allocate a new code, try again", { code: "unavailable", requestId });
  }

  // All other actions forward straight to the code's DO.
  const known = ["join", "pull", "presence", "push", "setrole", "setname", "leave"];
  if (known.includes(action)) {
    const code = normalizeCode(body.code);
    const r = await callDO(env, code, action, body);
    return reply(r, requestId);
  }

  return errJson(404, "Unknown household action", { code: "notFound", requestId });
}
