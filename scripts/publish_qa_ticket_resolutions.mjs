// QA ticket-only publication. Dry run by default; never publishes device verdicts.
// Uses the existing authenticated app bridge and preserves the latest full ticket.
import fs from 'node:fs';
import path from 'node:path';

const input = process.argv.find(value => value.endsWith('.json'));
if (!input) throw new Error('Provide a resolution JSON path; add --publish only after validation passes.');
const resolutions = JSON.parse(fs.readFileSync(input, 'utf8'));
const base = 'https://api.sowensstudios.com';
const publish = process.argv.includes('--publish');
async function collection() {
  let response;
  // The unified bridge can briefly return 503 while its backing worker wakes or
  // compacts. A ticket publication re-reads the collection before every write,
  // so a one-shot failure made safe batches unnecessarily fragile. Retry only
  // transient statuses; authorization/schema errors still fail immediately.
  for (let attempt = 0; attempt < 30; attempt += 1) {
    response = await fetch(`${base}/_unified/qa/tickets/sync?source=stocked-app&limit=1000`, {
      method: 'POST', headers: {'X-QA-Passcode': 'Joo'}, signal: AbortSignal.timeout(30000),
    });
    if (response.ok || (response.status !== 429 && response.status < 500)) break;
    if (attempt < 29) {
      await new Promise(resolve => setTimeout(resolve, Math.min(2_000, 400 * (attempt + 1))));
    }
  }
  if (!response.ok) throw new Error(`Ticket sync failed: ${response.status}`);
  const body = await response.json();
  if (!body.ok || !Array.isArray(body.tickets) || body.summary?.total > body.tickets.length) {
    throw new Error('Incomplete cross-device collection; refusing to publish.');
  }
  return body;
}
function workerKey() {
  const value = process.env.STOCKED_WORKER_KEY || fs.readFileSync(path.resolve('Secrets.xcconfig'), 'utf8')
    .match(/^\s*STOCKED_WORKER_KEY\s*=\s*(.+)$/m)?.[1]?.trim().replace(/^"|"$/g, '');
  if (!value || value.includes('$(') || /\s/.test(value)) throw new Error('Worker authentication is not configured.');
  return value;
}
let snapshot = await collection();
console.log(`Read ${snapshot.tickets.length} cross-device tickets; ${resolutions.length} scoped resolutions.`);
for (const resolution of resolutions) {
  let ticket = snapshot.tickets.find(ticket => ticket.number === resolution.number);
  // Exact completed entries are read-only: the fresh batch snapshot is enough to
  // skip them and avoids repeatedly waking the bridge for historical resolutions.
  if (ticket?.status === 'fixed' && ticket.resolution === resolution.resolution) {
    console.log(`${ticket.number}: already updated`); continue;
  }
  if (publish) {
    snapshot = await collection(); // Don't overwrite a newly edited unresolved ticket with an old snapshot.
    ticket = snapshot.tickets.find(ticket => ticket.number === resolution.number);
  }
  if (!ticket || ticket.title !== resolution.title) throw new Error(`Target changed: ${resolution.number}`);
  if (!['open', 'investigating', 'fixed'].includes(ticket.status)) throw new Error(`Unexpected status: ${ticket.number}`);
  if (typeof resolution.resolution !== 'string' || !resolution.resolution.includes('Physical-device verification pending')) {
    throw new Error(`Resolution must disclose the verification boundary: ${ticket.number}`);
  }
  if (ticket.status === 'fixed' && ticket.resolution === resolution.resolution) {
    console.log(`${ticket.number}: already updated`); continue;
  }
  const updatedAt = new Date().toISOString();
  const updated = {...ticket, status: 'fixed', resolution: resolution.resolution, updatedAt};
  const payload = JSON.stringify({schema: 'stocked-qa-report/v1', source: 'stocked-app',
    kind: 'tickets', generatedAt: updatedAt, tickets: [updated]});
  if (Buffer.byteLength(payload) > 256 * 1024) throw new Error(`Ticket exceeds bridge limit: ${ticket.number}`);
  if (!publish) { console.log(`${ticket.number}: would mark code fixed (${Buffer.byteLength(payload)} bytes)`); continue; }
  const response = await fetch(`${base}/qa/reports`, {method: 'POST',
    headers: {'Content-Type': 'application/json', 'X-Stocked-Key': workerKey()},
    body: payload, signal: AbortSignal.timeout(30000)});
  if (!response.ok) throw new Error(`Publish failed for ${ticket.number}: HTTP ${response.status}`);
  const accepted = await response.json();
  if (accepted.ok !== true) throw new Error(`Bridge rejected ${ticket.number}`);
  console.log(`${ticket.number}: code fixed; device verification pending`);
}
if (publish) {
  const final = await collection();
  for (const resolution of resolutions) {
    const ticket = final.tickets.find(t => t.number === resolution.number);
    if (ticket?.status !== 'fixed' || ticket.resolution !== resolution.resolution) throw new Error(`Read-back mismatch: ${resolution.number}`);
  }
  console.log(`Verified ${resolutions.length} resolutions by read-back. Collection still contains ${final.tickets.length} tickets.`);
}
