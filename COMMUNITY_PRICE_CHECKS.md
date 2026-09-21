# Saved community price checks

Open **Kitchen Toolbox → Price Lookup → Saved community price checks**, or Settings → Data &
Storage → Free Kitchen Connections. Save a barcode, currency, target price and price basis. Optional
country/city fields limit where reports must come from. Blank location fields allow reports anywhere;
there is no distance estimate. Choose the maximum report age and whether discounts may qualify.

Press **Check saved prices now** or check one barcode. Work is sequential, limited to 20 saved checks,
uses at most the provider's 25 returned observations per barcode, and cancels when leaving the screen
or backgrounding. A local one-minute retry gap and server rate limits protect the free service.
No automatic schedule, closed-app monitoring, retailer quote or price guarantee is provided.

Only an exact matching currency and price basis can qualify. Unknown/invalid/future dates, unknown
units, different currencies, different selected locations and excluded discounts are not guessed.
The age window includes today: "last 30 days" means today and the previous 29 calendar days, measured
in UTC because the source supplies date-only observations. Ties use lower price, then newer date,
then stable observation ID. Discount conditions and actual availability must be checked at the source.
The result is the lowest qualifying report among the returned bounded sample, not the world's best price.

Failures retain the last successful result with its check time and a visible "not refreshed" message.
An edit invalidates the prior result and rejects an older in-flight response. A deleted or paused check
cannot be repopulated by a delayed lookup. Editing an open draft detects another configuration edit
while preserving normal network-result refreshes. Clear/erase cancels tasks and removes device alerts.

Alerts are optional, requested only by the user's toggle through NotificationPermissionCoordinator.
They are local notifications after an explicit successful check, not server monitoring. Existing iOS
permission must allow notifications. Rechecking the same matching observation does not alert again.
The notification uses a generic message; barcode, product name, location and target are not on the
lock screen. Disabling alerts or removing a check clears its pending/delivered notifications.

## Ownership and privacy

CommunityPriceWatchStore persists device-only settings and recent results through the existing
FeatureStore/LocalDatabase owner. It is registered for lifecycle flush, disk usage and erase.
These are device preferences: no household schema, receipt-history write or Kitchen Transfer backup
field is added. Configure checks separately on another device. There is no credential to provide.

The existing authenticated Worker `/prices/community` endpoint receives only the barcode. Targets
and location filters stay on the device. Open Prices observations remain separate from personal
price history; the app links to original reports and carries Open Prices ODbL/OpenStreetMap credits.
The old Worker `/prices/watch` endpoint is a legacy save scaffold and is not used by this feature.
No paid retailer, currency, AI or analytics request is introduced.

## Verification

```sh
xcrun swiftc Stocked/CommunityPricesCore.swift scripts/CommunityPriceWatchChecks.swift -o /tmp/stocked-community-watch-checks
/tmp/stocked-community-watch-checks
```

31 native checks passed: currency/basis/discount/location/date boundaries, exact age/leap days,
unknown and malformed facts, stable price ordering and alert identity, bounded work, input validation
and local Codable roundtrip. The complete app build validates UIKit/UserNotifications integration.
Actual permission sheets, delivery, cancellation UI and relaunch/disk behavior require device QA;
native checks do not claim those passes. No simulator or actual notification was sent during these checks.
