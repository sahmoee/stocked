# Apply HomeBase sync to Stocked

The two Swift files are additive (no existing files touched). Do these manual steps from the
current export (they can't be shipped safely as blind edits):

## 1) Secrets.xcconfig  (git-ignored)  — append:
    // "//" is a comment in xcconfig, so URLs use the $() trick:
    HOMEBASE_URL = http:/$()/your-mac.your-tailnet.ts.net:8080
    HOMEBASE_API_KEY = hb_paste_your_key_here

## 2) Info.plist  (start from the CURRENT export) — add:
    HomeBaseURL                      String   $(HOMEBASE_URL)
    HomeBaseAPIKey                   String   $(HOMEBASE_API_KEY)
    NSLocalNetworkUsageDescription   String   Stocked connects to your HomeBase server on your Mac to sync your pantry.
  Plus a NARROW ATS exception (not NSAllowsArbitraryLoads) — see the connect guide 2.4.

## 3) StockedApp.swift — wire the store:
    @StateObject private var server = StockedServerStore()
    // in the WindowGroup content:
        .environmentObject(server)
        .task { await server.start() }

## 4) Use it anywhere (offline-first; nothing sent until configured):
    server.save(PantryItem(name: "Milk", quantity: 1, zone: "Fridge"))
    server.deleteItem(id: item.id)
    let fileID = server.uploadReceipt(jpegData: photo)     // saved locally now, uploaded later
    let jpeg = await server.receiptData(fileID: fileID)
    // views bind to server.visibleItems ; server.storageOnline == false -> show a quiet banner

## Offline behavior (built in)
- Items load instantly from an on-device cache (Application Support/StockedServer/items.json).
- Edits work with no connection; they persist and queue in a durable outbox and flush when the
  server (and its drive) come back. Receipts are stored on the phone immediately.
- Live changes from other devices merge in via WebSocket (last-writer-wins).
