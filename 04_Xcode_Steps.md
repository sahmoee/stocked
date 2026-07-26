# Manual steps to finish (Xcode / hosting)

The code is in place. These few things can't be done from outside Xcode/App Store Connect.

## 1. Universal links — put your Team ID in the AASA
`site/.well-known/apple-app-site-association` uses `TEAMID.com.sowens.Stocked`. Replace `TEAMID` with your 10-character Apple Team ID (Membership page in the developer portal), then deploy the Netlify site. Verify:
```
curl -s https://sowensstudios.com/.well-known/apple-app-site-association | jq .
```
It must return JSON with `Content-Type: application/json` (the `netlify.toml` header handles this). Then clean-build the app so the entitlement takes effect and test by scanning a container-label QR.

## 2. StoreKit config — attach to the scheme
`Stocked.storekit` exists but Xcode only uses it if the scheme points at it:
Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Options ▸ StoreKit Configuration ▸ select `Stocked.storekit`. Then IAP works in the simulator without App Store Connect. **Also confirm** the product ID `com.stocked.householdsync` matches App Store Connect exactly — it's in a different namespace than the bundle (`com.sowens.Stocked`), which is legal but easy to typo.

## 3. CI — share the scheme + add a test target
`.github/workflows/ci.yml` runs `xcodebuild … test`. For that to pass:
- Product ▸ Scheme ▸ Manage Schemes ▸ tick **Shared** for `Stocked`.
- Ensure the `StockedTests` target is in the scheme's Test action (Edit Scheme ▸ Test ▸ +).
- Adjust the simulator name/OS in the workflow if your runner image differs.
Until the test target is wired, change the workflow's `test` to `build` to keep CI green.

## 4. Localization — how to extend
`en.lproj/Localizable.strings` is the base table. To migrate a view, replace `Text("Add")` with `Text(String(localized: "action.add"))` and add the key to the table. To add a language, duplicate `en.lproj` as e.g. `es.lproj`, translate the values, and add the language under the project's Localizations. Do it view-by-view; nothing breaks if a string isn't migrated yet.

## 5. New files
No action — the project uses synchronized file groups, so the new `.swift` files (and `en.lproj`, `Stocked.storekit`) are picked up automatically. Just build. If any new view should also belong to a *different* target, set membership in the File Inspector.

## 6. Widgets
The two new widgets are in the existing `StockedWidgets` target and auto-register. After building, long-press the Home Screen ▸ add widget ▸ Stocked to see "Expiring Soon" and "Grocery List".
