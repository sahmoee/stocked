import Foundation

/// The recipe browser only opens public web pages, never app schemes, local files,
/// embedded credentials or literal private/local addresses. Browsing preserves anchors.
/// This is navigation validation, not a DNS firewall or publisher access bypass.
nonisolated enum RecipeBrowserPolicy {
  static func url(_ input: String) -> URL? {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 8192,
      !value.contains(where: { $0.isWhitespace || $0.isNewline }),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !value.contains("\\")
    else { return nil }
    if value.hasPrefix("//") {
      value = "https:" + value
    } else if !value.contains(":") {
      value = "https://" + value
    }
    guard var parts = URLComponents(string: value),
      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
      parts.user == nil, parts.password == nil,
      let host = parts.host?.lowercased(), host.contains("."),
      host.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
      }),
      !host.split(separator: ".").allSatisfy({
        $0.range(of: #"^(?:0x[0-9a-f]+|[0-9]+)$"#, options: .regularExpression) != nil
      }),
      !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
      !host.hasSuffix("."), !host.contains(".."),
      host.split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
      !host.contains(":"), host.contains(where: \.isLetter),
      host != "localhost",
      parts.port == nil || parts.port == 443 || (scheme == "http" && parts.port == 80)
    else { return nil }
    parts.scheme = "https"
    if parts.port == 80 { parts.port = nil }
    return parts.url
  }

  /// Remove only known advertising trackers. `ref`/`source` and all other query
  /// parameters can identify the recipe itself and must not be silently dropped.
  static func importURL(_ input: String) -> URL? {
    guard let url = url(input), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    parts.fragment = nil
    parts.queryItems = parts.queryItems?.filter {
      !$0.name.lowercased().hasPrefix("utm_")
        && !["fbclid", "gclid", "igshid"].contains($0.name.lowercased())
    }
    if parts.queryItems?.isEmpty != false { parts.query = nil }
    return parts.url
  }

  static func hostLabel(_ url: URL?) -> String {
    guard let host = url?.host?.lowercased() else { return "Recipe website" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  static func sameDocument(_ lhs: URL?, _ rhs: URL?) -> Bool {
    guard let lhs, let rhs,
      var a = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
      var b = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
    else { return false }
    a.fragment = nil
    b.fragment = nil
    return a.url == b.url
  }
}

nonisolated struct RecipeBrowserPageState {
  enum Phase { case empty, loading, ready, failed }
  var phase: Phase = .empty
  var loadedURL: URL?
  var message: String?
  var importURL: URL? { phase == .ready ? loadedURL : nil }
  mutating func started() {
    phase = .loading
    loadedURL = nil
    message = nil
  }
  mutating func finished(_ url: URL?) {
    guard let url, let safe = RecipeBrowserPolicy.url(url.absoluteString) else {
      failed("This page can’t be imported.")
      return
    }
    loadedURL = safe
    phase = .ready
    message = nil
  }
  mutating func failed(_ text: String) {
    phase = .failed
    loadedURL = nil
    message = text
  }
}

/// Shared by WebKit navigation and the bounded network importer. A displayed error
/// document, PDF, image or archive must never become an importable recipe page.
nonisolated enum RecipePageResponsePolicy {
  static let maximumHTMLBytes = 3_000_000
  static func failure(status: Int, mimeType: String?, expectedBytes: Int64 = -1) -> String? {
    switch status {
    case 200..<300: break
    case 401, 403:
      return "This website requires access or sign-in. You can try opening it in your browser."
    case 404, 410:
      return "This recipe link is no longer available. Try another recipe on this website."
    case 429: return "This website is receiving too many requests. Please try again later."
    default: return "This website couldn’t load the page (\(status)). Try again shortly."
    }
    if let mimeType, !["text/html", "application/xhtml+xml"].contains(mimeType.lowercased()) {
      return "This link opens a file, not a recipe web page. You can view it in your browser."
    }
    if expectedBytes > maximumHTMLBytes {
      return "This page is too large to import safely. Try the individual recipe page."
    }
    return nil
  }
  static func message(for error: Error) -> String {
    if let failure = error as? RecipePageLoadError { return failure.message }
    switch (error as NSError).code {
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
      return "You’re offline. Reconnect, then tap Try again."
    case NSURLErrorTimedOut:
      return "This page is taking too long. Try again or open it in your browser."
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
      NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
      return "A secure connection couldn’t be established. Stocked won’t bypass certificate checks."
    default: return "We couldn’t load this page. Check the link and try again."
    }
  }
}

nonisolated struct RecipePageLoadError: Error, Sendable { let message: String }

/// Validate each redirect before URLSession follows it, not merely the final URL.
/// This still does not claim to prevent DNS rebinding or bypass publisher access.
nonisolated final class RecipePageRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url, let safe = RecipeBrowserPolicy.url(url.absoluteString) else {
      completionHandler(nil)
      return
    }
    var next = request
    next.url = safe
    completionHandler(next)
  }
}

/// Immediate cancellation invalidates progress/results even if an underlying page
/// script or provider finishes late. Starting again cannot revive an old draft.
nonisolated struct RecipeBrowserImportState {
  private(set) var generation = UUID()
  private(set) var isRunning = false
  mutating func begin() -> UUID {
    generation = UUID()
    isRunning = true
    return generation
  }
  mutating func cancel() {
    generation = UUID()
    isRunning = false
  }
  func accepts(_ token: UUID) -> Bool { isRunning && token == generation }
  mutating func finish(_ token: UUID) { if accepts(token) { isRunning = false } }
}
