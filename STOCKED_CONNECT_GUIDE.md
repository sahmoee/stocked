# Connect "Stocked" to HomeBase

Nothing from HomeBase gets bundled into your app. Stocked just talks to the
server over HTTP/WebSocket — you add **one client file, one config file, and
two Info.plist entries**. The same recipe works for every future app.

What Stocked gets:
- Store/read JSON data under the `Stocked` project (`/v1/Stocked/{collection}`)
- Store/read **files** (receipt photos etc.) on the server's drive
  (`/v1/Stocked/files/{id}`)
- Live pushes when anything changes on another device
- Clean handling when the Mac's storage drive is unplugged (503 → retry;
  a push tells the app the moment it's back)

> Requires HomeBase 1.1 (this delivery adds the file endpoints — rebuild the
> app with `Build HomeBase.app.command` from the updated HomeBase folder).

---

## Part 1 — Server side (one time, ~3 minutes, on the Mac)

1. Launch **HomeBase.app**. Storage tab → make sure a store is **Active**
   (attach your SSD, or "Set Up HomeBase Here" if it's new).
2. **Projects & Keys** tab → under Projects, add `Stocked`.
3. Still there → **New API Key…**
   - Label: `Sam's iPhone — Stocked` (one key per device is the habit)
   - Limit to project: `Stocked`  ← keys scoped per app can't touch other apps' data
   - **Copy the `hb_…` key now** — it's shown once.
4. **Server** tab → note the URLs (localhost / LAN IP / your Tailscale name)
   and turn on **Open HomeBase at login**.

Sanity check from Terminal (replace KEY):

```sh
curl http://localhost:8080/health
curl -H "Authorization: Bearer hb_KEY" -H "Content-Type: application/json" \
     -d '{"data":{"name":"Milk","quantity":1,"zone":"Fridge"}}' \
     http://localhost:8080/v1/Stocked/items
```

---

## Part 2 — Add server access to the Stocked Xcode project

### 2.1 Add the two Swift files
Drag into the project navigator (✓ *Copy items if needed*, ✓ Stocked target):
- `HomeBaseClient.swift` — the networking layer (REST + WebSocket + files)
- `StockedServerStore.swift` — a ready observable store wired for Stocked
  (items sync + receipt files); adapt or use as reference

`HomeBaseConfig` lives at the top of `StockedServerStore.swift` — if Stocked
already has a `BuildConfig`, you can fold those two properties into it instead.

### 2.2 Secrets (never in source)
Stocked already uses the `Secrets.xcconfig` → Info.plist → `BuildConfig`
pattern for `stockedWorkerSharedKey`. Append two lines to that same
**Secrets.xcconfig** (git-ignored):

```
// xcconfig gotcha: "//" starts a comment, so URLs need the $() trick.
HOMEBASE_URL = http:/$()/sowens-mac.your-tailnet.ts.net:8080
HOMEBASE_API_KEY = hb_paste_the_key_from_part_1_here
```

(For home-Wi-Fi-only testing you can use the LAN IP instead, e.g.
`http:/$()/192.168.1.20:8080`. Tailscale is the "works anywhere" answer.)

If the project doesn't have an xcconfig wired up yet: File → New → File →
Configuration Settings File → `Secrets.xcconfig`, then Project → Info →
Configurations → set Debug and Release to it, and add `Secrets.xcconfig` to
`.gitignore`.

### 2.3 Info.plist entries
Add (Raw Keys view):

| Key | Type | Value |
|---|---|---|
| `HomeBaseURL` | String | `$(HOMEBASE_URL)` |
| `HomeBaseAPIKey` | String | `$(HOMEBASE_API_KEY)` |
| `NSLocalNetworkUsageDescription` | String | `Stocked connects to your HomeBase server on your Mac to sync your pantry.` |

### 2.4 ATS (plain http to your own server only)
The server speaks plain HTTP; on LAN and inside Tailscale that's fine (Tailscale
traffic is end-to-end encrypted). Add a **narrow** exception — not
`NSAllowsArbitraryLoads`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>          <!-- LAN IPs -->
  <key>NSExceptionDomains</key>
  <dict>
    <key>ts.net</key>                                 <!-- your tailnet host -->
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      <key>NSIncludesSubdomains</key><true/>
    </dict>
  </dict>
</dict>
```

### 2.5 Start it
Wherever Stocked boots (e.g. the `App` struct):

```swift
@StateObject private var server = StockedServerStore()
// ...
.environmentObject(server)
.task { await server.start() }
```

---

## Part 3 — Using it in Stocked

```swift
// Save / update a pantry item (syncs to every device, pushes live)
try await server.save(PantryItem(name: "Milk", quantity: 1, zone: "Fridge"), id: item.id)

// Delete (tombstones propagate everywhere)
try await server.deleteItem(id: item.id)

// Store a receipt photo ON THE SERVER'S DRIVE and get its id back
let fileID = try await server.uploadReceipt(jpegData: photoData)

// Fetch it later (any device)
let jpeg = try await server.receiptData(fileID: fileID)
```

`server.items` is a published dictionary your views can render directly;
`server.storageOnline == false` means the Mac's drive is unplugged — show a
quiet banner, keep working locally, and the store resyncs itself the moment
the `storage online` push arrives.

Note the split: the **Cloudflare worker** keeps doing Stocked's AI calls
(receipt OCR, recipes); **HomeBase** is where the data and the photos live.
A nice pattern: photo → upload to HomeBase (keeps the original) → send text/
image to the worker for parsing → save parsed items to `/v1/Stocked/items`.

### Test checklist
- [ ] `/health` shows `"storage":"online"` from the phone's network
- [ ] Create an item on the phone → it appears in a `curl` list from the Mac
- [ ] Second device (or simulator) sees it appear live, no refresh
- [ ] Unplug the SSD → app shows offline state, nothing crashes; replug →
      resync happens by itself
- [ ] Upload a receipt → file exists in `HomeBaseData/files/Stocked/` on the SSD

---

## Part 4 — Every future app (Atlas, The Sesh, BabySteps, …)

Zero server changes, ever. Per app:

1. HomeBase → Projects & Keys → add the project name, create a key scoped to it.
2. Copy the same two files into that app; change **one line**
   (`HomeBaseConfig.project = "Atlas"`); add its key to that app's
   `Secrets.xcconfig`; repeat 2.3–2.4.
3. Each app's data lives under its own `/v1/{Project}/…` namespace and its own
   `files/{Project}/` folder — scoped keys mean apps can't read each other.

Building a new app from scratch? HomeBase → Instructions tab → export
`NEW_PROJECT_BUILD_BRIEF.md` + `HomeBaseClient.swift` and paste them into
Claude with one line describing the app.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `401 unauthorized` | Key typo/revoked, or key scoped to a different project. |
| `403 forbidden_project` | Key is scoped to another project — make a `Stocked` key. |
| `503 storage_offline` | The Mac's drive is unplugged — Storage tab, or just plug it in. |
| Can't connect on LAN | Phone on same Wi-Fi? iOS Local Network permission granted (Settings → Privacy → Local Network)? Mac firewall allowing HomeBase? |
| Can't connect via Tailscale | Tailscale VPN toggled on the phone, same tailnet, `http://` not `https://`. |
| ATS error in console | Revisit 2.4 — the exception domain must match your host. |
| xcconfig URL becomes `http:` | Use the `http:/$()/host` trick — `//` is a comment in xcconfig. |
