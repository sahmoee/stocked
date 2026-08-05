# ⛔️ DEPRECATED — do not deploy this worker

`stocked-receipt-worker` has been superseded by the unified **`sowens-worker`**
(the `worker/` project in your Documents folder). Do **not** run
`wrangler deploy` in this directory.

## Why `wrangler deploy` here fails (error 10061)

    ✘ Cannot create binding for class 'HouseholdDO' because it is not currently
      configured to implement Durable Objects. [code: 10061]

This failure is expected. The `HouseholdDO` Durable Object namespace
(`stocked-receipt-worker_HouseholdDO`, ~12.1k requests of **live household
data**) is being **transferred** to `sowens-worker`, not recreated here. A
Durable Object class belongs to exactly one Worker script, so this script can
no longer own it.

## Deploy the unified worker instead

    cd ../../worker          # → Documents/worker   (name = "sowens-worker")
    npx wrangler deploy

That deploy runs the one-time `v1-unify` migration, which:

  - transfers **HouseholdDO** (from here) and **SocialDO + RoomDO** (from
    `sesh-worker`) using `transferred_classes`, and
  - creates **RateLimiter + LoungeDO** fresh.

## ⚠️ Do NOT "fix" this by recreating the class

Do not add or bump a migration in this folder to
`new_sqlite_classes = ["HouseholdDO"]`. It would deploy cleanly but create an
**empty** namespace and orphan every existing household. The live data only
moves via the `transferred_classes` migration in `worker/wrangler.toml`. This
is a one-time, irreversible migration — deploy `sowens-worker` deliberately,
from the correct Cloudflare account.

## After the transfer succeeds

Once `sowens-worker` is deployed and verified, this folder can be removed. Its
routes and logic were folded into `sowens-worker`.

---
_Deprecation notice added 2026-08-01. See `worker/wrangler.toml` for the full
migration plan and the dashboard namespace notes._
