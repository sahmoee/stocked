# Free connections

`FreeKitchenConnectionsView` adds two optional, user-operated iOS connections. There is no new
subscription, paid API, hosted AI, Worker proxy, background task, or automatic two-way sync.
You need an existing Grocy or CalDAV service that you control or are allowed to use. Hosting costs,
if any, depend on that existing service; Stocked does not provision a server.

## Grocy → Stocked

1. Open **Free connections → Grocy inventory and shopping → Set up connection**.
2. Enter the HTTPS web address or `/api` address of your Grocy installation and a Grocy API key.
   Grocy manages its keys in its own settings. The key is placed in the `GROCY-API-KEY` header,
   never in a URL.
3. Choose **Read Grocy now**. Review the Inventory and Shopping rows, choose their storage area,
   confirm container counts where needed, and select up to 50 additions.
4. Confirm the displayed import. Successful additions use Stocked's existing inventory proposal
   owner or grocery store, including household permissions, normal sharing and persistence.

This is an **append-only import**. An existing item, a stronger duplicate found by the product
reconciler, or a previously imported Grocy row is kept. Changed remote rows say to compare and edit
the existing item in Inventory/Grocery List. There is no overwrite, remote purchase, consume,
delete, or Grocy shopping-list change. A source row disappearing does not remove local food.

Grocy quantities use the product's stock unit. Only a positive whole value with an explicit
piece/item/unit/each unit suggests a container count. Weights, volumes, custom units and fractions
require the user to confirm a package count. Earliest due dates are comparison notes, not an
expiry assignment to every package. No prices, quantities, locations or expiry facts are invented.

Reads are limited to 500 stock rows, 500 shopping rows, 2,000 products and 1,000 quantity units;
responses above a limit fail clearly. Four serial GETs use `/stock`, `/objects/shopping_list`,
`/objects/products`, and `/objects/quantity_units`, with limit/order parameters on entity lists.
Each response is capped at 2 MiB while streaming. Previews expire for importing after ten minutes.
The UI shows 40 rows at a time and can reveal more. Changes are rechecked immediately before each
addition. Cancellation keeps completed additions and stops starting further ones.

Local replay protection retains at most 5,000 endpoint/household/source hashes. It refuses new
imports when this ledger is full rather than silently evicting old import identities. Names are
also checked against the current household lists, including additions arriving from another device.
The replay ledger is device-local, not a distributed transaction ledger; deliberately removed or
renamed items should be reconciled manually across devices.

## Stocked → CalDAV

1. Open **Free connections → Meals on your calendar → Set up connection**.
2. Enter an HTTPS **calendar home URL** or a calendar's full CalDAV URL, username and app-specific
   password. A generic login page is not a calendar URL. Username/password authentication is
   supported; browser-only/OAuth-only services can use the existing `.ics` export instead.
3. Choose **Find my calendars**, select the destination calendar, and choose either the active
   week or dated plans. Check the active week's starting date. Dated plans can show a 14-, 30-,
   or 90-day window; skipped/moved records are excluded from that source list.
4. Select up to 50 meals and **Check calendar entries**. Review each create/update/conflict result,
   then explicitly confirm **Publish reviewed meals**.

Published copies are private, transparent all-day events containing only meal title, meal slot,
date and servings. They contain no ingredient list, account secret, household code, member name,
recipe instructions or attachments. “Private” is an event property, not a replacement for the
calendar server's own sharing/access settings.

Dated meals retain deterministic UIDs when their date or title changes. Active-week copies use
the meal identity plus the explicitly reviewed date, because the legacy active plan stores
relative days. Publishing a different active-week date can create another copy; it does not remove
an earlier event. Changes in a calendar never alter meals, groceries or inventory in Stocked.

Safety rules:

- Discovery is a bounded Depth-1 PROPFIND of the supplied calendar/home URL. Calendar hrefs must
  remain on that exact HTTPS origin. There is no cross-server credential forwarding or automatic
  discovery through arbitrary principals, redirects or service records.
- XML is UTF-8, limited to 512 KiB, 100 response elements, 24 nesting levels and bounded property
  text. DTDs/entities are rejected, and external entity resolution is disabled.
- Every selected destination object is read before review. New writes use `If-None-Match: *`.
- Updates require a locally recorded Stocked publication, its unchanged strong ETag and byte hash,
  the expected UID/Stocked marker, and no invitation/recurrence fields. Writes use the reviewed
  `If-Match` value. Other or externally edited events remain conflicts and cannot be forced through.
- When a PUT omits its ETag, the following GET must exactly match the submitted bytes before its
  ETag becomes a baseline. Server normalization or another writer's intervening edit cannot silently
  become permission for a later overwrite. A write may have succeeded even when confirmation fails;
  refresh the preview before retrying.
- No DELETE, automatic replay, remote event cleanup, or unattended publication exists. At most
  500 local receipt hashes/ETags are retained; an evicted receipt makes an existing event a protected
  conflict, not an unowned update candidate. Disconnect leaves remote events unchanged.

## Credentials, ownership and reset

`KitchenConnectionVault` stores the address, username and key/password in generic-password Keychain
items with `WhenUnlockedThisDeviceOnly` and synchronization disabled. Credentials are excluded from
household payloads, app exports/backups and logs. Connection forms never display a saved password.
Changing the server or username requires deliberate re-entry of the secret.

Transport uses an ephemeral, cookie-free, cache-free URLSession without credential storage,
25-second request/35-second resource timeouts and streamed byte caps. Redirects are refused,
including same-origin redirects, so enter the final URL. The system validates HTTPS certificates;
there is no self-signed-certificate bypass. LAN hosts still require trusted HTTPS and the normal
iOS local-network permission. Requests are explicit and serial; rate limits stop the operation
rather than triggering retries or background loops. Errors never echo server bodies or secrets.

The owning app is Stocked iOS. StockedMac, UnifiedWorker, the site and extensions do not receive
connection settings or run these operations. Existing household inventory/grocery owners remain
authoritative; `PlanAheadStore`/`plannedMeals` are read-only sources for calendar export.

`try KitchenConnectionReset.clearLocalState()` clears local replay/publication ledgers, attempts
both Keychain deletions and invalidates unfinished connector batches. It never changes either
remote service. The clear-all owner surfaces a persistent sanitized warning if Keychain removal
fails, with a retry action after the device is unlocked. An already-dispatched remote request cannot
be recalled; subsequent batch requests are blocked after reset. Each new read/import/publication
checks the saved Keychain identity again, so an open screen cannot reconnect using credentials
removed or changed by another app flow. An in-flight request cannot restore a cleared local receipt.
The transport also rechecks that identity and the captured reset revision before every individual
request, including Grocy's later list reads and CalDAV's optional post-write GET. Revocation stops
those follow-up requests even while the original operation is still open.

## Validation and sources

The standalone harness uses production parsers/client logic plus a fake transport; it makes no real
server calls and creates no Keychain item:

```
swiftc Stocked/PlanAheadCore.swift Stocked/MealPlanExchange.swift \
  Stocked/FreeKitchenConnectionCore.swift Stocked/FreeKitchenConnectionClient.swift \
  scripts/FreeConnectionChecks.swift -o /tmp/stocked-free-connection-checks
/tmp/stocked-free-connection-checks
```

It checks quantity ambiguity, row/body bounds, endpoint/credential confinement, hostile XML,
deterministic identities, date rollover, calendar escaping/folding, ownership and strong-ETag
conflicts, conditional request headers, and the missing-PUT-ETag/intervening-edit regression.
Fake-transport regressions revoke access after the first request and verify that no remaining
Grocy read or CalDAV post-write GET is dispatched.
Generic iOS compilation complements these checks. Real server interoperability, device Keychain
reset/unlock behavior, local-network permission and UI/accessibility flows still require device QA;
the harness does not mark those passed.

The clients are original implementations against the [Grocy OpenAPI specification](https://github.com/grocy/grocy/blob/master/grocy.openapi.json),
[CalDAV RFC 4791](https://www.rfc-editor.org/rfc/rfc4791.html),
[WebDAV RFC 4918](https://www.rfc-editor.org/rfc/rfc4918.html), and
[iCalendar RFC 5545](https://www.rfc-editor.org/rfc/rfc5545.html).
No Grocy implementation or third-party client library is bundled. Contributor/license acknowledgements
are in Settings → Help → Sources & Credits and `THIRD_PARTY_NOTICES.md`.
