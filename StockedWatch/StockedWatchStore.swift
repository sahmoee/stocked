import SwiftUI
import UserNotifications
import WatchKit
import WatchConnectivity

@MainActor @Observable final class StockedWatchStore {
    struct Saved: Codable {
        var version = 1
        var snapshot: KitchenWatch.Snapshot?
        var outbox = KitchenWatch.Outbox()
        var recipes: [KitchenWatch.RecipeDetail] = []
        var receipts: [KitchenWatch.Receipt] = []
        var steps: [String: Int] = [:]
    }
    private(set) var saved = Saved()
    var message: String?
    var operationIssue: String?
    private func report(_ text: String) { message = text; operationIssue = text }
    private(set) var reachable = false
    private(set) var storageReady = true
    @ObservationIgnored private let transport = KitchenWatchTransport()
    @ObservationIgnored private var resend: Task<Void, Never>?
    @ObservationIgnored private var requestNonce: UUID?
    var snapshot: KitchenWatch.Snapshot? { saved.snapshot }
    var pending: [KitchenWatch.Command] { saved.outbox.pending }
    init() {
        do {
            saved = try KitchenWatchDisk.load(Saved.self, name: "watch-state") ?? Saved()
            guard saved.version == 1, saved.outbox.pending.count <= KitchenWatch.queueLimit,
                  saved.recipes.count <= 8, saved.snapshot?.isValid != false else { throw KitchenWatch.Failure.incompatible }
        } catch { storageReady = false; report("Saved Watch data could not be read. Changes are paused; your iPhone kitchen is safe.") }
        transport.receive = { [weak self] data in self?.receive(data) }
        transport.changed = { [weak self] in
            guard let self else { return }
            self.reachable = self.transport.reachable
            self.refresh(); self.flush()
        }
        transport.start()
    }
    func active() {
        if let scope = snapshot?.scope {
            var next = saved; next.outbox.reconcile(scope: scope)
            if next.outbox.pending.count < saved.outbox.pending.count { report(next.outbox.history.first?.message ?? "A queued change needs review.") }
            commit(next)
        }
        refresh(); flush()
    }
    func refresh(recipe: UUID? = nil, section: String? = nil, query: String? = nil, offset: Int? = nil) {
        let nonce = UUID(); requestNonce = nonce
        guard let data = try? KitchenWatch.Packet(request: .init(recipe: recipe, section: section, query: query, offset: offset, nonce: nonce)).encoded() else { return }
        transport.context(data); transport.send(data)
        if !transport.reachable { message = "Requested an update. Saved information remains available while iPhone reconnects." }
    }
    func handoff(_ section: String) {
        if let data = try? KitchenWatch.Packet(request: .init(handoff: section)).encoded() { transport.context(data); transport.send(data) }
        message = "Open Stocked on your iPhone to continue."
    }
    func can(_ operation: KitchenWatch.Operation) -> Bool {
        storageReady && snapshot?.enabled == true && snapshot?.permissions.contains(operation.permission) == true && pending.count < KitchenWatch.queueLimit
    }
    func changing(_ id: UUID) -> Bool { pending.contains { $0.target == id || $0.id == id } }
    func send(_ operation: KitchenWatch.Operation, target: UUID? = nil, baseline: Double? = nil, name: String? = nil,
              number: Int? = nil, flag: Bool? = nil, value: String? = nil, date: Date? = nil) {
        guard let scope = snapshot?.scope, can(operation) else { report(pending.count >= KitchenWatch.queueLimit ? "The 64-change queue is full. Connect iPhone before adding more." : "Connect iPhone and check household permissions first."); return }
        if let target, changing(target) { report("Wait for this item's earlier change to finish before editing it again."); return }
        let command = KitchenWatch.Command(scope: scope, operation: operation, target: target, baseline: baseline, name: name, number: number, flag: flag, value: value, date: date)
        if let error = command.validation() { report(error); return }
        do {
            var next = saved; try next.outbox.enqueue(command)
            guard commit(next) else { return }
            message = "Queued for iPhone"; flush()
        } catch { report("This change could not be queued. Connect iPhone and try again.") }
    }
    private func flush() {
        guard transport.ready, storageReady else { return }
        for command in pending.prefix(8) {
            guard command.validation() == nil else { continue }
            if let data = try? KitchenWatch.Packet(command: command).encoded() { transport.send(data, durableID: command.id) }
        }
        resend?.cancel()
        if !pending.isEmpty {
            resend = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.active()
            }
        }
    }
    private func receive(_ data: Data) {
        guard let packet = try? KitchenWatch.Packet.decode(data) else { message = "Update Stocked on iPhone and Watch to the same version."; return }
        var next = saved
        if let incoming = packet.snapshot {
            guard KitchenWatch.accepts(incoming, current: next.snapshot, nonce: requestNonce) else {
                if incoming.scope != next.snapshot?.scope, requestNonce == nil { refresh() }
                return
            }
            if incoming.handshake == requestNonce { requestNonce = nil }
            if incoming.scope != next.snapshot?.scope || !incoming.enabled { next.recipes.removeAll(); next.steps.removeAll() }
            next.snapshot = incoming
            next.outbox.reconcile(scope: incoming.scope)
            if next.outbox.pending.count < saved.outbox.pending.count { report(next.outbox.history.first?.message ?? "A queued change needs review.") }
            if let detail = incoming.detail {
                next.recipes.removeAll { $0.id == detail.id }; next.recipes.insert(detail, at: 0)
                next.recipes = Array(next.recipes.prefix(8))
            }
            if !incoming.notice.isEmpty { message = incoming.notice }
        }
        if let receipt = packet.receipt, pending.contains(where: { $0.id == receipt.id && $0.scope == receipt.scope }) {
            next.receipts.removeAll { $0.id == receipt.id }; next.receipts.append(receipt)
        }
        // Keep pending overlays until an accepted change's authoritative snapshot has arrived.
        for receipt in next.receipts where receipt.canComplete(in: next.snapshot) {
            next.outbox.receive(receipt); next.receipts.removeAll { $0.id == receipt.id }
            message = receipt.message
            if receipt.result != .accepted { operationIssue = receipt.message }
        }
        if commit(next) { flush() }
    }
    @discardableResult private func commit(_ next: Saved) -> Bool {
        guard storageReady else { return false }
        do { try KitchenWatchDisk.save(next, name: "watch-state"); saved = next; return true }
        catch { report("Watch storage is full or unavailable. No unsaved change was sent."); return false }
    }
    func recipe(_ id: UUID) -> KitchenWatch.RecipeDetail? { saved.recipes.first { $0.id == id } }
    func step(_ id: UUID) -> Int { saved.steps[id.uuidString] ?? 0 }
    func setStep(_ step: Int, recipe: UUID, total: Int) {
        var next = saved
        next.steps[recipe.uuidString] = min(max(0, total - 1), max(0, step))
        if next.steps.count > 32 { next.steps = next.steps.filter { key, _ in next.recipes.contains { $0.id.uuidString == key } } }
        commit(next)
    }
    func clearDownloads() {
        guard pending.isEmpty else { message = "Finish queued changes before clearing downloads."; return }
        var next = saved; next.snapshot = nil; next.recipes.removeAll(); next.steps.removeAll(); commit(next)
    }
    func drainBackgroundDelivery() async {
        // Delegate data commits hop to this actor. Yield until WC has drained and the actor has
        // had two turns to finish its synchronous atomic commits; cancellation leaves durable work.
        var stable = 0
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            if transport.ready && !WCSession.default.hasContentPending { stable += 1 } else { stable = 0 }
            if stable >= 2 { flush(); return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

@MainActor @Observable final class StockedWatchTimer {
    struct State: Codable { var id = UUID(); var title = "Kitchen timer"; var duration: Double = 300; var deadline: Date?; var paused: Double = 300 }
    private(set) var state = State()
    var notice: String?
    private var request: Task<Void, Never>?
    init() {
        if let restored = try? KitchenWatchDisk.load(State.self, name: "watch-timer"),
           restored.duration.isFinite, (1...86400).contains(restored.duration), restored.paused.isFinite,
           restored.deadline?.timeIntervalSince1970.isFinite != false { state = restored }
    }
    var remaining: Double { max(0, min(86400, state.deadline?.timeIntervalSinceNow ?? state.paused)) }
    var running: Bool { state.deadline != nil && remaining > 0 }
    var finished: Bool { state.deadline != nil && remaining == 0 }
    func start(seconds: Double, title: String = "Kitchen timer") {
        guard seconds.isFinite, (1...86400).contains(seconds) else { notice = "Choose 1 second to 24 hours."; return }
        let next = State(id: UUID(), title: KitchenWatch.text(title, limit: 100), duration: seconds, deadline: Date().addingTimeInterval(seconds), paused: seconds)
        replace(next)
    }
    func pause() { var next = state; next.paused = remaining; next.deadline = nil; replace(next) }
    func resume() { guard state.paused > 0 else { return }; start(seconds: state.paused, title: state.title) }
    func reset() { var next = state; next.deadline = nil; next.paused = next.duration; replace(next) }
    private func replace(_ next: State) {
        do { try KitchenWatchDisk.save(next, name: "watch-timer") }
        catch { notice = "Timer could not be saved. Free Watch storage and retry."; return }
        request?.cancel()
        let old = "stocked.watch.timer." + state.id.uuidString
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [old])
        state = next
        guard let deadline = next.deadline else { return }
        request = Task { [weak self] in
            let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            guard !Task.isCancelled, let self, self.state.id == next.id else { return }
            guard allowed else { self.notice = "Timer is running. Enable notifications in Watch settings for an alert while the app is closed."; return }
            let seconds = deadline.timeIntervalSinceNow
            guard seconds > 0 else { return }
            let content = UNMutableNotificationContent(); content.title = next.title; content.body = "Your Stocked timer is finished."; content.sound = .default
            let id = "stocked.watch.timer." + next.id.uuidString
            do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1,seconds), repeats: false))) }
            catch { self.notice = "Timer is running, but its background alert could not be scheduled." }
            if Task.isCancelled || self.state.id != next.id { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id]) }
        }
    }
}
