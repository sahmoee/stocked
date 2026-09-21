// QASyncDestinations.swift
// ─────────────────────────────────────────────────────────────────────────────
// Where a QA ticket goes: three places, independently.
//
// THE PROBLEM THIS SOLVES
// Build 72 shipped with tickets riding the /qa/reports envelope, and the field
// export showed the weakness immediately: the envelope is capped at 256 KB, so
// the *screenshot never went anywhere*. Every ticket arrived with
// `"hasScreenshot": true` and no picture, which is worse than no claim at all.
// And even when the text arrived, it arrived in a Cloudflare KV namespace — a
// place nobody browses. The evidence existed in three fragments, none of which
// were somewhere a person actually looks.
//
// So a ticket now fans out to three destinations that fail independently:
//
//   1. WORKER (`/qa/reports` + the new `/qa/shots`). Text in the envelope as
//      before, plus a small base64 thumbnail inline so a report is never
//      *completely* blind, plus the full JPEG posted separately to a route with
//      its own, much larger cap. Survives the phone being wiped.
//   2. FOLDER (iCloud Drive → Stocked → QA). A real directory tree — one folder
//      per ticket, containing the report as Markdown, the screenshot, the
//      mockup, and both handoff blocks. This is the destination the request was
//      actually about: it appears in Finder on the Mac, by itself, with no
//      server, no deploy and no credential. It is also the only one that works
//      on a plane.
//   3. cPANEL (optional). A PHP receiver on the existing host, for when the
//      files should live somewhere a browser can reach and iCloud cannot. Off
//      unless a URL and token are entered in QA settings; `isConfigured` is
//      false and the destination is not even mentioned in the UI until then.
//
// WHY THREE AND NOT ONE
// Because they fail in completely different ways. The worker fails when the
// tester is offline. The folder fails when iCloud is signed out or the device is
// out of space. cPanel fails when a token rotates. A single destination means
// one of those failures loses the report; three means a failure loses a *copy*.
// Each has its own timestamp on the ticket for exactly this reason — a single
// `syncedAt` cannot express "the worker has it, the Mac does not", which is the
// state worth being able to see.
//
// WHY NETLIFY IS NOT ONE OF THEM
// It was considered and rejected. The site is static hosting: there is no
// writable filesystem, so accepting an upload would mean a Netlify Function plus
// an external blob store — i.e. all of the worker's complexity, with a second
// set of credentials, to reach the same kind of place the worker already is. It
// would add a destination without adding a *failure mode that is not already
// covered*, which is the only reason to add one.
//
// THREADING
// The folder mirror is an `actor`, deliberately. Resolving the iCloud container
// blocks — sometimes for seconds on first use after a cold launch — and writing
// a bundle is half a dozen file operations. None of that belongs on the main
// actor behind a tester's tap. The actor also serialises writes, so two tickets
// syncing at once cannot interleave inside the same directory.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import CryptoKit
import SwiftUI
import UIKit

// MARK: - cPanel settings

/// Configuration for the optional cPanel receiver.
///
/// `nonisolated` and UserDefaults-backed because `QATicket.destinationLine` —
/// itself nonisolated, on a Sendable struct — asks whether this destination is
/// configured in order to decide whether to mention it at all. UserDefaults is
/// safe to read from any thread.
///
/// THE TOKEN IS NOT A SECRET IN THE APP'S SENSE. It is a shared word between
/// this build and a PHP script the user installed on their own host, entered by
/// hand on the device, and it grants nothing but "may drop a file in a QA
/// folder". It is stored in UserDefaults, not the keychain, on purpose: it must
/// be readable without a prompt from a background sync, and putting it in the
/// keychain would imply a level of protection that would then be misleading.
/// No *vendor* key is ever stored on device — that rule is unchanged.
nonisolated enum QACPanelSettings {
    static let urlKey   = "qa.cpanel.url"
    static let tokenKey = "qa.cpanel.token"

    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                        forKey: urlKey) }
    }

    static var token: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                        forKey: tokenKey) }
    }

    /// True only when both halves are present *and* the URL parses. A half
    /// configured destination that reports itself as configured shows up as a
    /// permanently-missing destination on every ticket, which reads as a bug in
    /// the sync rather than an unfinished setting.
    static var isConfigured: Bool {
        let e = endpoint
        guard !e.isEmpty, !token.isEmpty, let u = URL(string: e), let host = u.host, !host.isEmpty
        else { return false }
        // The token is sent as a cleartext multipart field on every sync (see
        // `QACPanelClient.upload` below). Scheme used to be checked only for
        // non-nil, which accepted `http://`, so a pasted or autofilled plain
        // HTTP endpoint would silently send that token unencrypted on every
        // ticket. Require https unless the host is local — matches what the
        // token actually protects.
        let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        guard u.scheme == "https" || isLocal else { return false }
        return true
    }

    static var url: URL? { isConfigured ? URL(string: endpoint) : nil }
}

// MARK: - What travels to a destination

/// Everything one ticket needs to be written anywhere, snapshotted on the main
/// actor and then handed off.
///
/// The images are `Data`, not `UIImage`, on purpose: `UIImage` is not usefully
/// Sendable, and every destination wants JPEG bytes anyway. Converting once here
/// also means a ticket with a large screenshot is encoded a single time rather
/// than once per destination.
nonisolated struct QASyncBundle: Sendable {
    let ticket: QATicket
    let reportText: String
    let promptText: String
    let handbackText: String
    let shot: Data?
    let mockup: Data?

    var number: String { ticket.number }

    /// Folder name for this ticket: `STK-73-0004 — title`, sanitised. Leading
    /// with the number keeps a directory listing sorted in filing order, and the
    /// title is appended because scanning forty folders called STK-73-00xx to
    /// find "the one about the photo" is exactly the tedium this is meant to
    /// remove.
    var folderName: String {
        let cleanTitle = ticket.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = cleanTitle.count > 48 ? String(cleanTitle.prefix(48)) + "…" : cleanTitle
        return short.isEmpty ? ticket.number : "\(ticket.number) — \(short)"
    }
}

/// Outcome of one destination attempt. Carries a reason on failure because
/// "sync failed" with no explanation sends people to the wrong place — usually
/// the network, when the real answer was "you are signed out of iCloud".
nonisolated enum QASyncOutcome: Sendable {
    case ok
    case skipped(String)
    case failed(String)

    var succeeded: Bool { if case .ok = self { return true }; return false }
    var note: String {
        switch self {
        case .ok:              return "ok"
        case .skipped(let r):  return "skipped — \(r)"
        case .failed(let r):   return "failed — \(r)"
        }
    }
}

// MARK: - Destination 1b: full screenshots to the Worker

/// Posts the full JPEG to `/qa/shots`, outside the report envelope.
///
/// SEPARATE ROUTE, NOT A BIGGER ENVELOPE. The report envelope's 256 KB cap is
/// what keeps a runaway breadcrumb list from wedging the bridge; raising it to
/// fit pictures would remove that protection from the text path too. A route
/// that only ever accepts one image, with its own cap and its own key prefix, is
/// both safer and easier to expire.
nonisolated enum QAShotUploader {

    /// Hard ceiling matching the Worker's. Screenshots are already downscaled to
    /// 900px/0.6 quality before they are stored, which lands around 100–200 KB,
    /// so this is a guard against something unexpected rather than a normal
    /// limit.
    static let maxBytes = 2 * 1024 * 1024

    static func upload(_ data: Data, number: String, kind: String) async -> QASyncOutcome {
        guard let base = URL(string: BuildConfig.receiptWorkerURL) else {
            return .skipped("no worker URL")
        }
        guard ConnectivityMonitor.isOnlineFlag else { return .skipped("offline") }
        guard !data.isEmpty else { return .skipped("no image") }
        guard data.count <= maxBytes else {
            return .failed("image is \(data.count / 1024) KB, over the \(maxBytes / 1024) KB limit")
        }

        var comps = URLComponents(url: base.appendingPathComponent("qa/shots"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "ticket", value: number),
                             URLQueryItem(name: "kind", value: kind)]
        guard let url = comps?.url else { return .failed("bad URL") }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue(number, forHTTPHeaderField: "X-QA-Ticket")
        req.setValue(kind, forHTTPHeaderField: "X-QA-Kind")
        BuildConfig.authorizeWorkerRequest(&req)
        req.httpBody = data

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) { return .ok }
            // 404 is the specific, expected failure until the Worker is
            // redeployed with the new route, and it deserves to say so rather
            // than being reported as a generic bad status. Everything else
            // still syncs; only the full-size image is missing.
            if code == 404 { return .skipped("worker has no /qa/shots route yet — redeploy it") }
            return .failed("worker returned \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Destination 2: the folder on the Mac

/// Mirrors tickets into a real directory tree, preferring the app's iCloud
/// Drive container so the result appears in Finder on the Mac with no server
/// involved at all.
///
/// LAYOUT
///   QA/
///     Build 73/
///       STK-73-0004 — Photo not loading/
///         report.md
///         screenshot.jpg
///         mockup.jpg
///         chatgpt-mockup-prompt.md
///         claude-handback.md
///       index.md            ← one line per ticket in this build
///     Logs/
///       2026-07-27 143200 qa-export.txt
///
/// GROUPED BY BUILD, NOT BY SESSION. A session boundary is invisible to the
/// person reading the folder — they think in builds ("did this happen before
/// 73?"), and a session folder per launch turns a week of testing into ninety
/// directories.
///
/// FALLBACK IS NOT AN ERROR. When iCloud is unavailable the tree is written to
/// the app's own Documents directory instead, which is exposed over File Sharing
/// and visible in the Files app under On My iPhone → Stocked. The mirror
/// reports which root it used rather than reporting failure, because a folder on
/// the phone is still a folder, and the alternative — refusing to write anything
/// — loses the evidence to save a sentence of explanation.
actor QAFolderMirror {
    static let shared = QAFolderMirror()

    private var cachedRoot: URL?
    private var resolvedOnce = false
    private(set) var lastRootDescription = "not resolved yet"
    private(set) var usingICloud = false

    private init() {}

    // MARK: Root resolution

    /// Resolve the QA root once per launch and remember it.
    ///
    /// `url(forUbiquityContainerIdentifier:)` is documented as potentially slow
    /// and must not be called on the main thread; being inside an actor is what
    /// makes that safe here. It is also called at most once per launch — the
    /// answer does not change mid-session in any way that matters, and calling
    /// it per ticket would put a multi-second stall behind a button.
    private func root() -> URL? {
        if resolvedOnce { return cachedRoot }
        resolvedOnce = true

        let fm = FileManager.default
        // Internal builds retain the compiler's source path. When that checkout
        // is writable, use the application-neutral Documents/Reports workspace;
        // each Unified Worker app owns a sibling folder beneath it.
        // Physical-device/App Store sandboxes cannot write there and naturally
        // continue to the iCloud/Documents fallback below.
        let source = URL(fileURLWithPath: #filePath)
        let project = source.deletingLastPathComponent().deletingLastPathComponent()
        let reports = project.deletingLastPathComponent()
            .appendingPathComponent("Reports", isDirectory: true)
            .appendingPathComponent("Stocked", isDirectory: true)
        if ensure(reports) && canWrite(reports) {
            cachedRoot = reports
            usingICloud = false
            lastRootDescription = reports.path
            return reports
        }
        if let container = fm.url(forUbiquityContainerIdentifier: nil) {
            // `Documents` inside the container is the part that is visible to
            // the user in Finder and Files. Anything written beside it is
            // synced but invisible, which for this feature is the same as not
            // having written it.
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            let qa = docs.appendingPathComponent("QA", isDirectory: true)
                .appendingPathComponent("Stocked", isDirectory: true)
            if ensure(qa) {
                cachedRoot = qa
                usingICloud = true
                lastRootDescription = "iCloud Drive → Stocked → QA"
                return qa
            }
        }

        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            lastRootDescription = "no writable location"
            return nil
        }
        let qa = docs.appendingPathComponent("QA", isDirectory: true)
        guard ensure(qa) else {
            lastRootDescription = "could not create the QA folder"
            return nil
        }
        cachedRoot = qa
        usingICloud = false
        lastRootDescription = "On My iPhone → Stocked → QA (iCloud unavailable)"
        return qa
    }

    private func ensure(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { return fm.isWritableFile(atPath: dir.path) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func canWrite(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".stocked-qa-write-probe")
        do {
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch { return false }
    }

    /// Human-readable description of where things are being written, for the QA
    /// settings screen. Forces resolution if it has not happened yet.
    func rootDescription() -> String {
        _ = root()
        return lastRootDescription
    }

    func rootPath() -> String? { root()?.path }

    // MARK: Writing

    /// Write (or rewrite) one ticket's folder. Idempotent: re-syncing an edited
    /// ticket overwrites in place rather than accumulating copies, because a
    /// folder holding three versions of the same report is a folder nobody
    /// trusts.
    func write(_ bundle: QASyncBundle) -> QASyncOutcome {
        guard let root = root() else { return .failed(lastRootDescription) }

        let buildDir = root.appendingPathComponent("Build \(bundle.ticket.context.build)",
                                                   isDirectory: true)
        guard ensure(buildDir) else { return .failed("could not create the build folder") }

        let dir = buildDir.appendingPathComponent(bundle.folderName, isDirectory: true)
        // A title edit changes the friendly folder name. Remove the prior folder
        // for the same immutable ticket number so stale versions do not linger.
        if let siblings = try? FileManager.default.contentsOfDirectory(at: buildDir,
                                                                        includingPropertiesForKeys: nil) {
            for old in siblings where old.hasDirectoryPath && old.lastPathComponent.hasPrefix(bundle.number + " ") && old != dir {
                try? FileManager.default.removeItem(at: old)
            }
        }
        guard ensure(dir) else { return .failed("could not create the ticket folder") }

        do {
            try write(bundle.reportText, to: dir.appendingPathComponent(QAMockupHandoff.reportFileName))
            try write(bundle.promptText, to: dir.appendingPathComponent(QAMockupHandoff.promptFileName))
            try write(bundle.handbackText, to: dir.appendingPathComponent(QAMockupHandoff.handbackFileName))

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let ticketJSON = try encoder.encode(bundle.ticket)
            try ticketJSON.write(to: dir.appendingPathComponent("ticket.json"), options: .atomic)

            if let shot = bundle.shot {
                try shot.write(to: dir.appendingPathComponent(QAMockupHandoff.shotFileName),
                               options: .atomic)
            }
            if let mockup = bundle.mockup {
                try mockup.write(to: dir.appendingPathComponent(QAMockupHandoff.mockupFileName),
                                 options: .atomic)
            }
            var files: [[String: Any]] = []
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                guard !file.hasDirectoryPath, file.lastPathComponent != "manifest.json",
                      let data = try? Data(contentsOf: file) else { continue }
                files.append(["name": file.lastPathComponent, "bytes": data.count,
                              "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
            }
            let manifest: [String: Any] = ["ticket": bundle.number,
                                           "updatedAt": ISO8601DateFormatter().string(from: Date()),
                                           "files": files.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .ok
    }

    /// Refresh `index.md` for a build — the file that makes the folder browsable
    /// without opening forty subdirectories.
    func writeIndex(build: Int, lines: [String], summary: String) -> QASyncOutcome {
        guard let root = root() else { return .failed(lastRootDescription) }
        let buildDir = root.appendingPathComponent("Build \(build)", isDirectory: true)
        guard ensure(buildDir) else { return .failed("could not create the build folder") }

        var out = ["# Stocked QA — build \(build)", "", summary, ""]
        out.append(contentsOf: lines.map { "- \($0)" })
        out.append("")
        out.append("_Updated \(Date().formatted()) by Stocked \(BuildConfig.version) (\(BuildConfig.buildNumber))._")

        do {
            try write(out.joined(separator: "\n"),
                      to: buildDir.appendingPathComponent("index.md"))
            try writeRootIndex()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .ok
    }

    private func writeRootIndex() throws {
        guard let root = root() else { return }
        let builds = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("Build ") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out = ["# Stocked QA Reports", "",
                   "Tickets, screenshots, diagnostics, run logs, and machine-readable exports generated automatically by internal QA.", ""]
        out += builds.map { "- [\($0.lastPathComponent)](<\($0.lastPathComponent)/index.md>)" }
        out += ["", "- [Logs](<Logs/>)", "", "_Updated \(Date().formatted())._"]
        try write(out.joined(separator: "\n"), to: root.appendingPathComponent("README.md"))
    }

    func removeTicket(number: String, build: Int) {
        guard let root = root() else { return }
        let buildDir = root.appendingPathComponent("Build \(build)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: buildDir,
                                                                       includingPropertiesForKeys: nil) else { return }
        for file in files where file.hasDirectoryPath && file.lastPathComponent.hasPrefix(number + " ") {
            try? FileManager.default.removeItem(at: file)
        }
        try? writeRootIndex()
    }

    /// Drop a plain-text QA export (the logs half of the request) into `Logs/`.
    /// Timestamped rather than overwritten: a log is a record of a moment, and
    /// overwriting yesterday's with today's would quietly destroy the thing that
    /// makes a trend visible.
    func writeLog(_ text: String, name: String) -> QASyncOutcome {
        guard let root = root() else { return .failed(lastRootDescription) }
        let dir = root.appendingPathComponent("Logs", isDirectory: true)
        guard ensure(dir) else { return .failed("could not create the Logs folder") }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HHmmss"
        // Include the build number so logs from different builds sort distinctly
        // and a new build's log never silently overwrites an older one.
        let build = BuildConfig.buildNumber
        let file = "\(fmt.string(from: Date())) b\(build) \(name)"
        do {
            try write(text, to: dir.appendingPathComponent(file))
        } catch {
            return .failed(error.localizedDescription)
        }
        return .ok
    }

    /// Continuously updated session report for tools that want one stable file.
    func writeLatestReport(_ text: String) -> QASyncOutcome {
        guard let root = root() else { return .failed(lastRootDescription) }
        let dir = root.appendingPathComponent("Logs", isDirectory: true)
        guard ensure(dir) else { return .failed("could not create the Logs folder") }
        do { try write(text, to: dir.appendingPathComponent("latest-qa-session.txt")); return .ok }
        catch { return .failed(error.localizedDescription) }
    }

    func writeStableLog(_ text: String, name: String) -> QASyncOutcome {
        guard let root = root() else { return .failed(lastRootDescription) }
        let dir = root.appendingPathComponent("Logs", isDirectory: true)
        guard ensure(dir) else { return .failed("could not create the Logs folder") }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        do { try write(text, to: dir.appendingPathComponent(safe)); return .ok }
        catch { return .failed(error.localizedDescription) }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

// MARK: - Destination 3: cPanel

/// Uploads a ticket bundle to a PHP receiver on the user's own host.
///
/// The wire format is deliberately dull — a single multipart POST with a JSON
/// part and up to two image parts — because the thing on the other end is a
/// thirty-line PHP file the user installs themselves, and every clever choice
/// here becomes a support problem there. The receiver script ships in this
/// delta at `cpanel/qa-receiver.php`.
nonisolated enum QACPanelClient {

    static func upload(_ bundle: QASyncBundle) async -> QASyncOutcome {
        guard QACPanelSettings.isConfigured, let url = QACPanelSettings.url else {
            return .skipped("cPanel not configured")
        }
        guard ConnectivityMonitor.isOnlineFlag else { return .skipped("offline") }

        let boundary = "stocked-qa-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        func file(_ name: String, _ filename: String, _ type: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }

        field("token", QACPanelSettings.token)
        field("ticket", bundle.number)
        field("folder", bundle.folderName)
        field("build", String(bundle.ticket.context.build))
        field("severity", bundle.ticket.severity.rawValue)
        field("status", bundle.ticket.status.rawValue)
        field("title", bundle.ticket.title)
        field(QAMockupHandoff.reportFileName, bundle.reportText)
        field(QAMockupHandoff.promptFileName, bundle.promptText)
        field(QAMockupHandoff.handbackFileName, bundle.handbackText)
        if let shot = bundle.shot {
            file("screenshot", QAMockupHandoff.shotFileName, "image/jpeg", shot)
        }
        if let mockup = bundle.mockup {
            file("mockup", QAMockupHandoff.mockupFileName, "image/jpeg", mockup)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) { return .ok }
            // Echo a short slice of the response: a misconfigured PHP host
            // answers with an HTML error page, and seeing the first line of it
            // is the difference between "it says 500" and knowing why.
            let hint = String(decoding: data.prefix(120), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("cPanel returned \(code)\(hint.isEmpty ? "" : " — \(hint)")")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Coordinator

/// Fans one ticket out to every destination and records what happened.
///
/// SEQUENTIAL, NOT CONCURRENT, AND ON PURPOSE. Three parallel uploads from a
/// phone on a weak connection contend for the same radio and all three time out
/// together; run in order, the folder write (which is local, instant, and the
/// one that matters most) has always completed before the network is touched.
/// The ordering is deliberate too: folder first, so a tester who kills the app
/// mid-sync still has the evidence.
@MainActor
@Observable
final class QASyncCoordinator {
    static let shared = QASyncCoordinator()

    private(set) var isRunning = false
    private(set) var lastOutcome = "not synced yet"
    private(set) var lastDetail: [String] = []
    private(set) var folderLocation = "not resolved yet"

    // `isRunning` only gates the settings-screen button; nothing stopped two
    // calls to `syncEverywhere` for the *same* ticket from overlapping — e.g.
    // `QATicketStore.setStatus`'s auto-publish task racing a manual "send
    // everything" tap, or (before that duplicate schedule was fixed) the
    // status-change path itself. An overlap meant a double POST to the
    // Worker, a double multipart upload to cPanel, and two folder-mirror
    // writes racing each other. Track in-flight ticket ids and no-op a
    // re-entrant call for the same id rather than let it double-send.
    private var inFlight: Set<UUID> = []

    private init() {}

    /// Unconditional local/project mirror. This is deliberately separate from
    /// network fan-out so saving evidence never depends on connectivity or the
    /// auto-publish preference.
    @discardableResult
    func mirrorTicket(_ id: UUID) async -> Bool {
        await QATicketStore.shared.awaitScreenshotWrite(id)
        guard let bundle = await QATicketStore.shared.bundle(for: id) else { return false }
        let outcome = await QAFolderMirror.shared.write(bundle)
        folderLocation = await QAFolderMirror.shared.rootDescription()
        if outcome.succeeded { QATicketStore.shared.stampMirrored(id) }
        let index = QATicketStore.shared.indexLines(forBuild: bundle.ticket.context.build)
        _ = await QAFolderMirror.shared.writeIndex(build: bundle.ticket.context.build,
                                                   lines: index.lines, summary: index.summary)
        QASyncQueue.shared.record(number: bundle.number, detail: ["folder: \(outcome.note)"])
        return outcome.succeeded
    }

    /// Refresh the human-readable folder location for the settings screen.
    func refreshFolderLocation() async {
        folderLocation = await QAFolderMirror.shared.rootDescription()
    }

    /// Send one ticket everywhere. Returns true when at least the folder or the
    /// worker took it — "everything failed" and "one optional destination is
    /// unconfigured" should not look the same to the caller.
    @discardableResult
    func syncEverywhere(_ id: UUID) async -> Bool {
        // Build 84 - screenshot bytes are written off-main now; make sure they
        // are on disk before the bundle reads them back for upload.
        await QATicketStore.shared.awaitScreenshotWrite(id)
        guard let bundle = await QATicketStore.shared.bundle(for: id) else {
            lastOutcome = "ticket not found"
            return false
        }
        guard !inFlight.contains(id) else {
            // A sync for this exact ticket is already running — this is the
            // overlap this method used to allow through. Let the one already
            // in flight own the fan-out; a second run would duplicate every
            // network side effect for no benefit.
            return false
        }
        inFlight.insert(id)
        isRunning = true
        defer { isRunning = false; inFlight.remove(id) }

        var detail: [String] = []
        var anyLanded = false
        // Counted separately from `detail` so the "N of M destinations" line
        // below always reflects the 3 conceptual destinations (folder/worker/
        // cPanel), not however many optional screenshot/mockup upload lines
        // happen to also be in `detail` that sync — attaching a screenshot
        // used to silently change both the numerator and denominator of that
        // ratio, so "2 of 3 destinations" could read as "3 of 5" once a
        // screenshot was present.
        var coreTotal = 0
        var coreOk = 0

        // 1. Folder — local, instant, no credential.
        let folder = await QAFolderMirror.shared.write(bundle)
        detail.append("folder: \(folder.note)")
        coreTotal += 1
        if folder.succeeded {
            anyLanded = true
            coreOk += 1
            QATicketStore.shared.stampMirrored(id)
        }
        folderLocation = await QAFolderMirror.shared.rootDescription()

        // Keep the browsable index honest on every sync rather than on a timer:
        // an index that is a few tickets behind is the kind of wrong that gets
        // believed.
        let build = bundle.ticket.context.build
        let index = QATicketStore.shared.indexLines(forBuild: build)
        _ = await QAFolderMirror.shared.writeIndex(build: build,
                                                   lines: index.lines,
                                                   summary: index.summary)

        // 2. Worker — text envelope, then the full image on its own route.
        let posted = await QATicketStore.shared.publish(id)
        detail.append("worker: \(posted ? "ok" : "failed")")
        coreTotal += 1
        if posted { anyLanded = true; coreOk += 1 }

        if let shot = bundle.shot {
            let up = await QAShotUploader.upload(shot, number: bundle.number, kind: "screenshot")
            detail.append("screenshot: \(up.note)")
            if up.succeeded { QATicketStore.shared.stampShotSynced(id) }
        }
        if let mockup = bundle.mockup {
            let up = await QAShotUploader.upload(mockup, number: bundle.number, kind: "mockup")
            detail.append("mockup: \(up.note)")
        }

        // 3. cPanel — optional, and silent when not set up.
        if QACPanelSettings.isConfigured {
            let cp = await QACPanelClient.upload(bundle)
            detail.append("cPanel: \(cp.note)")
            coreTotal += 1
            if cp.succeeded {
                anyLanded = true
                coreOk += 1
                QATicketStore.shared.stampCPanelSynced(id)
            }
        }

        lastDetail = detail
        // Build 74: `lastDetail` is overwritten by the next sync, so the reason a
        // destination failed used to live for exactly one sync and then vanish.
        // Every attempt is kept in the queue log instead.
        QASyncQueue.shared.record(number: bundle.number, detail: detail)
        lastOutcome = anyLanded
            ? "\(bundle.number) → \(coreOk) of \(coreTotal) destinations"
            : "\(bundle.number) reached nowhere"
        return anyLanded
    }

    /// Push every ticket that is missing from at least one destination.
    /// Sequential for the same reason as above.
    @discardableResult
    func syncAllPending() async -> Int {
        let imported = await QATicketStore.shared.pullDeviceTickets()
        if imported > 0 { lastDetail = ["devices: imported \(imported) ticket(s)"] }
        let pending = QATicketStore.shared.tickets
            .filter { !$0.isFullySynced }
            .map(\.id)
        guard !pending.isEmpty else {
            lastOutcome = "everything is already everywhere"
            return 0
        }
        var done = 0
        for id in pending {
            if await syncEverywhere(id) { done += 1 }
        }
        lastOutcome = "synced \(done) of \(pending.count)"
        return done
    }

    /// Write the full QA export into the Logs folder. Separate from tickets
    /// because it is the other half of the request — "reports / logs" — and
    /// because it is the artefact worth having when the question is "what was
    /// this build like overall", not "what happened in ticket four".
    @discardableResult
    func mirrorLog(_ text: String, name: String = "qa-export.txt") async -> Bool {
        guard !text.isEmpty else { return false }
        let out = await QAFolderMirror.shared.writeLog(text, name: name)
        lastOutcome = "log: \(out.note)"
        folderLocation = await QAFolderMirror.shared.rootDescription()
        return out.succeeded
    }

    /// Fetch the most recent report this app published to the worker and write
    /// it to the Logs folder. Useful when the iCloud sync lagged and the Mac
    /// does not yet have the latest version, or when testing from a fresh device.
    @discardableResult
    func fetchWorkerReportAndSave() async -> Bool {
        do {
            guard let report = try await QAReportTransport.fetchOwnReport() else {
                lastOutcome = "no report on the worker yet"
                return false
            }
            // Format as readable text — the raw JSON is already complete, but a
            // plain-text version is easier to grep and diff on the Mac.
            var lines = ["Stocked QA — worker report (fetched \(Date().formatted()))"]
            if let schema = report["schema"] as? String { lines.append("schema: \(schema)") }
            if let gen = report["generatedAt"] as? String { lines.append("generated: \(gen)") }
            if let app = report["app"] as? [String: Any] {
                let v = app["version"] as? String ?? "?"
                let b = app["build"] as? String ?? "?"
                lines.append("app: Stocked \(v) build \(b)")
            }
            if let signOff = report["signOff"] as? [String: Any] {
                let passed  = signOff["passed"]       as? Int ?? 0
                let failed  = signOff["failed"]       as? Int ?? 0
                let blocked = signOff["blocked"]      as? Int ?? 0
                let open    = signOff["openBlockers"]  as? Int ?? 0
                lines.append("sign-off: \(passed) passed · \(failed) failed · \(blocked) blocked · \(open) open blockers")
            }
            if let health = report["health"] as? [String: Any] {
                if let runs = health["invariantRuns"] as? Int { lines.append("invariant runs: \(runs)") }
                if let screens = health["screensVisited"] as? Int { lines.append("screens visited: \(screens)") }
                if let net = health["runtime"] as? [String: Any] {
                    let calls    = net["networkCalls"]    as? Int ?? 0
                    let failures = net["networkFailures"] as? Int ?? 0
                    lines.append("network: \(calls) calls · \(failures) failed")
                }
            }
            if let triage = report["triage"] as? [String: Any] {
                let verdict   = triage["verdict"]  as? String ?? "?"
                let blockers  = triage["blockers"] as? Int    ?? 0
                let warnings  = triage["warnings"] as? Int    ?? 0
                lines.append("triage: \(verdict) · \(blockers) blockers · \(warnings) warnings")
                if let findings = triage["findings"] as? [[String: Any]] {
                    for f in findings.prefix(20) {
                        let level  = f["level"]  as? String ?? "?"
                        let title  = f["title"]  as? String ?? "?"
                        let detail = f["detail"] as? String ?? ""
                        lines.append("  [\(level)] \(title)\(detail.isEmpty ? "" : " — \(detail)")")
                    }
                }
            }
            let text = lines.joined(separator: "\n")
            return await mirrorLog(text, name: "worker-report-fetched.txt")
        } catch {
            lastOutcome = "fetch failed: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Settings screen

/// Where reports go, and the state of each destination.
///
/// The screen leads with the folder because that is the destination the request
/// was about and the one that needs no setup — it either works or it says why in
/// a sentence. cPanel is last and collapsed behind two empty fields, because it
/// is the only one that can be got wrong.
struct QASyncSettingsView: View {
    @State private var sync = QASyncCoordinator.shared
    @State private var store = QATicketStore.shared
    @State private var endpoint = QACPanelSettings.endpoint
    @State private var token = QACPanelSettings.token
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Folder", value: sync.folderLocation)
                    .font(.stocked(.callout))
                Button {
                    Task { await sync.refreshFolderLocation() }
                } label: {
                    Label("Check the folder again", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("On your Mac")
            } footer: {
                Text("Every send writes a folder per ticket — the report as Markdown, the screenshot, the mockup, and both handoff blocks — plus an index for the build and a timestamped copy of the QA log. With iCloud Drive on, it appears in Finder under iCloud Drive → Stocked → QA within a few seconds. With iCloud unavailable it is written on the phone instead, under On My iPhone → Stocked in the Files app, and syncs when iCloud returns.")
            }

            Section {
                Button {
                    guard !busy else { return }
                    busy = true
                    Task {
                        let n = await sync.syncAllPending()
                        _ = await sync.mirrorLog(store.exportText)
                        note = n == 0 ? sync.lastOutcome : "Sent \(n) ticket\(n == 1 ? "" : "s")."
                        busy = false
                    }
                } label: {
                    Label("Send everything that is missing", systemImage: "arrow.up.doc.on.clipboard")
                }
                .disabled(busy || sync.isRunning)

                Button {
                    guard !busy else { return }
                    busy = true
                    Task {
                        let ok = await sync.mirrorLog(store.exportText)
                        note = ok ? "QA log written to the Logs folder." : sync.lastOutcome
                        busy = false
                    }
                } label: {
                    Label("Write the QA log to the folder", systemImage: "doc.text")
                }
                .disabled(busy)

                Button {
                    guard !busy else { return }
                    busy = true
                    Task {
                        let ok = await sync.fetchWorkerReportAndSave()
                        note = ok ? "Worker report saved to the Logs folder." : sync.lastOutcome
                        busy = false
                    }
                } label: {
                    Label("Fetch latest worker report → Logs", systemImage: "arrow.down.doc")
                }
                .disabled(busy)

                if busy || sync.isRunning {
                    HStack(spacing: 8) { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                }
                if let note {
                    Text(note).font(.stocked(.caption)).foregroundStyle(.secondary)
                }
                ForEach(sync.lastDetail, id: \.self) { line in
                    Text(line).font(.stocked(.caption).monospaced()).foregroundStyle(.secondary)
                }
            } header: {
                Text("Send")
            } footer: {
                Text(sync.lastOutcome)
            }

            Section {
                TextField("https://sowensstudios.com/qa/qa-receiver.php", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Shared token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    QACPanelSettings.endpoint = endpoint
                    QACPanelSettings.token = token
                    note = QACPanelSettings.isConfigured
                        ? "cPanel destination saved."
                        : "Both a full https URL and a token are needed before cPanel is used."
                } label: {
                    Label("Save cPanel destination", systemImage: "square.and.arrow.down")
                }
                if QACPanelSettings.isConfigured {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.stockedGreen)
                        .font(.stocked(.caption))
                }
            } header: {
                Text("cPanel (optional)")
            } footer: {
                Text("Upload `cpanel/qa-receiver.php` from this build's delta to your host, set the same token inside it, and paste its URL here. Until both fields are filled in, cPanel is skipped silently and is not counted as a missing destination on any ticket. The token is a shared word between this phone and your own script — it is not a vendor key and grants nothing beyond dropping a file in the QA folder.")
            }

            Section {
                LabeledContent("Worker", value: BuildConfig.receiptWorkerURL)
                    .font(.stocked(.caption).monospaced())
            } footer: {
                Text("Ticket text rides the /qa/reports envelope with a small thumbnail inside it. Full screenshots go to /qa/shots, which needs the Worker to have been redeployed — until then the screenshot line reports that route as missing and everything else still syncs.")
            }
        }
        .navigationTitle("Reports & logs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sync.refreshFolderLocation() }
    }
}
