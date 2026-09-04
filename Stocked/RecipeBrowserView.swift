import SwiftUI
import WebKit

@Observable @MainActor
final class RecipeBrowserController: NSObject, WKNavigationDelegate, WKUIDelegate {
  var page = RecipeBrowserPageState()
  var address = ""
  var title = ""
  var progress = 0.0
  var canGoBack = false
  var canGoForward = false
  var notice: String?
  var zoom = 1.0
  @ObservationIgnored weak var webView: WKWebView?
  @ObservationIgnored private var navigation: WKNavigation?
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored private var watchdog: Task<Void, Never>?
  @ObservationIgnored private var loadID = UUID()
  @ObservationIgnored private var loadStarted = Date()

  var currentURL: URL? { RecipeBrowserPolicy.url(address) }
  var history: [WKBackForwardListItem] {
    Array((webView?.backForwardList.backList ?? []).suffix(10).reversed())
  }

  func attach(_ view: WKWebView) {
    webView = view
    // One observation set per view; no polling and no repeated page loads.
    observations = [
      view.browserObserve(\.estimatedProgress), view.browserObserve(\.title),
      view.browserObserve(\.url),
      view.browserObserve(\.canGoBack), view.browserObserve(\.canGoForward),
    ]
  }
  func syncPage() {
    guard let view = webView else { return }
    progress = min(1, max(0, view.estimatedProgress))
    title = page.phase == .ready ? String((view.title ?? "").prefix(512)) : ""
    canGoBack = view.canGoBack
    canGoForward = view.canGoForward
    // Anchors/history.replaceState don't always send a navigation callback.
    if let url = view.url, page.phase == .ready, !view.isLoading {
      address = url.absoluteString
      page.finished(url)
    }
  }
  func open(_ text: String) {
    guard let url = RecipeBrowserPolicy.url(text) else {
      notice = "Enter a public website link, such as https://example.com/recipe."
      return
    }
    address = url.absoluteString
    beginLoading()
    navigation = webView?.load(URLRequest(url: url, timeoutInterval: 30))
  }
  func retry() { if let url = currentURL { open(url.absoluteString) } }
  func back() {
    guard canGoBack else { return }
    beginLoading()
    navigation = webView?.goBack()
  }
  func forward() {
    guard canGoForward else { return }
    beginLoading()
    navigation = webView?.goForward()
  }
  func go(to item: WKBackForwardListItem) {
    beginLoading()
    navigation = webView?.go(to: item)
  }
  func stop(_ message: String = "Loading stopped. Tap Try again when you’re ready.") {
    QARecorder.shared.record(
      .note, screen: "Recipe Browser", label: "Page loading stopped", detail: message)
    navigation = nil
    watchdog?.cancel()
    loadID = UUID()
    webView?.stopLoading()
    page.failed(message)
  }
  func pause() {
    webView?.pauseAllMediaPlayback(completionHandler: nil)
    if page.phase == .loading {
      stop("Loading paused while Stocked was in the background. Tap Try again to continue.")
    }
  }
  func detach(_ view: WKWebView) {
    guard webView === view else { return }
    watchdog?.cancel()
    observations.removeAll()
    navigation = nil
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
    webView = nil
    QARecorder.shared.record(.note, screen: "Recipe Browser", label: "Browser resources released")
  }
  func setZoom(_ value: Double) {
    zoom = min(1.6, max(0.8, value))
    webView?.pageZoom = zoom
    QARecorder.shared.record(.note, screen: "Recipe Browser", label: "Page zoom changed")
  }
  func findInPage() {
    webView?.findInteraction?.presentFindNavigator(showingReplace: false)
    QARecorder.shared.record(.note, screen: "Recipe Browser", label: "Find on page opened")
  }
  func jumpToRecipe() {
    let url = page.importURL
    webView?.evaluateJavaScript(RecipePageMarkup.jumpScript) { [weak self] result, _ in
      guard let self, self.page.importURL == url else { return }
      self.notice =
        (result as? Bool) == true
        ? "Jumped to the recipe." : "This page doesn’t expose a recipe section. Try Find on page."
      announceAccessibilityStatus(self.notice ?? "")
      QARecorder.shared.record(
        .note, screen: "Recipe Browser", label: "Jump to recipe",
        detail: (result as? Bool) == true ? "Recipe anchor found" : "No recipe anchor")
    }
  }
  func renderedPage() async -> (html: String, url: URL)? {
    guard let url = page.importURL, let webView else { return nil }
    let value = try? await webView.evaluateJavaScript(RecipePageMarkup.snapshotScript)
    guard !Task.isCancelled, page.importURL == url,
      let snapshot = value as? [String: Any], let path = snapshot["url"] as? String,
      let actual = RecipeBrowserPolicy.url(path), RecipeBrowserPolicy.sameDocument(actual, url),
      let html = snapshot["html"] as? String, !html.isEmpty, html.utf8.count <= 2_200_000
    else { return nil }
    return (html, actual)
  }
  private func beginLoading() {
    if page.phase != .loading {
      loadStarted = Date()
      QARecorder.shared.record(.note, screen: "Recipe Browser", label: "Page loading started")
    }
    page.started()
    progress = 0
    title = ""
    notice = nil
    watchdog?.cancel()
    loadID = UUID()
    let id = loadID
    watchdog = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, self.loadID == id, self.page.phase == .loading else { return }
      self.stop("This page is taking too long. Try again or open it in your browser.")
    }
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    self.navigation = navigation
    beginLoading()
    if let url = webView.url { address = url.absoluteString }
  }
  func webView(
    _ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
  ) {
    guard self.navigation === navigation else { return }
    if let url = webView.url { address = url.absoluteString }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard self.navigation === navigation else { return }
    watchdog?.cancel()
    address = webView.url?.absoluteString ?? address
    page.finished(webView.url)
    syncPage()
    QARecorder.shared.record(
      .success, screen: "Recipe Browser", label: "Page loaded",
      detail: String(format: "%.2f seconds", Date().timeIntervalSince(loadStarted)))
    announceAccessibilityStatus(
      "Page loaded. \(title.isEmpty ? RecipeBrowserPolicy.hostLabel(webView.url) : title)")
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { failed(navigation, error: error) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed(navigation, error: error)
  }
  private func failed(_ navigation: WKNavigation?, error: Error) {
    guard self.navigation === navigation, (error as NSError).code != NSURLErrorCancelled else {
      return
    }
    watchdog?.cancel()
    page.failed(RecipePageResponsePolicy.message(for: error))
    QARecorder.shared.record(
      .failure, screen: "Recipe Browser", label: "Page loading failed",
      detail: "Error code \((error as NSError).code); retry available")
    syncPage()
    announceAccessibilityStatus(page.message ?? "Page couldn’t load")
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    stop("The browser stopped to free memory. Tap Try again to reopen the page.")
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let main = action.targetFrame == nil || action.targetFrame?.isMainFrame == true
    guard let raw = action.request.url, let safe = RecipeBrowserPolicy.url(raw.absoluteString)
    else {
      if main {
        notice = "This link can’t open inside Stocked. Only public web pages are supported."
      }
      decisionHandler(.cancel)
      return
    }
    if action.shouldPerformDownload {
      if main { notice = "This link downloads a file. Open the recipe web page instead." }
      decisionHandler(.cancel)
      return
    }
    // User-activated target=_blank follows here; scripted popups cannot replace
    // a recipe and unsupported subframes cannot navigate the main document.
    if action.targetFrame == nil {
      decisionHandler(.cancel)
      if action.navigationType == .linkActivated { open(safe.absoluteString) }
      return
    }
    if safe != raw {
      decisionHandler(.cancel)
      if main { open(safe.absoluteString) }
      return
    }
    decisionHandler(.allow)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
  ) {
    if response.isForMainFrame {
      let status = (response.response as? HTTPURLResponse)?.statusCode ?? 200
      if let message = RecipePageResponsePolicy.failure(
        status: status, mimeType: response.response.mimeType)
      {
        stop(message)
        decisionHandler(.cancel)
        return
      }
    }
    decisionHandler(response.canShowMIMEType ? .allow : .cancel)
  }
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
  ) {
    notice = "Recipe websites can’t use your camera or microphone inside Stocked."
    decisionHandler(.deny)
  }
}

extension WKWebView {
  fileprivate func browserObserve<Value>(_ keyPath: KeyPath<WKWebView, Value>)
    -> NSKeyValueObservation
  {
    observe(keyPath, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        (self?.navigationDelegate as? RecipeBrowserController)?.syncPage()
      }
    }
  }
}

private struct RecipeBrowserWebContent: UIViewRepresentable {
  let controller: RecipeBrowserController
  let initialURL: URL?
  let surface: Color
  func makeCoordinator() -> RecipeBrowserController { controller }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = controller
    view.uiDelegate = controller
    view.allowsBackForwardNavigationGestures = true
    view.isFindInteractionEnabled = true
    view.isOpaque = false
    view.scrollView.keyboardDismissMode = .onDrag
    view.accessibilityLabel = "Recipe website content"
    controller.attach(view)
    updateUIView(view, context: context)
    if let initialURL { controller.open(initialURL.absoluteString) }
    return view
  }
  // Never reload the original URL on a SwiftUI redraw/theme change.
  func updateUIView(_ view: WKWebView, context: Context) {
    view.backgroundColor = UIColor(surface)
    view.scrollView.backgroundColor = UIColor(surface)
    view.underPageBackgroundColor = UIColor(surface)
  }
  static func dismantleUIView(_ view: WKWebView, coordinator: RecipeBrowserController) {
    coordinator.detach(view)
  }
}

/// Chrome grows with Dynamic Type and scrolls only after its width/height budget
/// is exhausted, leaving usable page space in landscape and small split windows.
private struct RecipeBrowserChrome<Content: View>: View {
  let maximumHeight: CGFloat
  @ViewBuilder let content: () -> Content
  @State private var contentHeight: CGFloat = 0
  var body: some View {
    ScrollView {
      content().frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(contentHeight > 0 ? contentHeight : maximumHeight, maximumHeight))
  }
}

struct RecipeBrowserView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  var initialURL: URL? = nil
  @State private var browser = RecipeBrowserController()
  @State private var addressText = ""
  @State private var importState = RecipeBrowserImportState()
  @State private var stage = ""
  @State private var importError: String?
  @State private var importTask: Task<Void, Never>?
  @State private var draft: Draft?
  @State private var pendingDuplicate: Draft?
  @State private var showDuplicate = false
  @State private var duplicate: UserRecipe?
  @State private var imported: UserRecipe?
  @State private var showImported = false
  @State private var confirmClose = false
  @FocusState private var addressFocused: Bool
  private struct Draft: Identifiable {
    let id = UUID()
    var form: AddRecipeForm
    var source: String
  }
  private var importing: Bool { importState.isRunning }
  private var surface: Color { RecipeCardStyle.surface(isDark: session.isDarkMode) }
  private var accent: Color { session.isDarkMode ? .stockedGoldDark : .stockedGold }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          RecipeBrowserChrome(maximumHeight: geometry.size.height * 0.35) {
            VStack(spacing: 0) {
              addressBar
              OfflineBanner()
              if let notice = browser.notice { messageRow(notice) { browser.notice = nil } }
              if let importError { importFailure(importError) }
              if importing {
                HStack {
                  ProgressView().tint(accent)
                  Text(stage).font(.stocked(.body))
                }
                .padding(12).frame(maxWidth: .infinity).background(surface)
              }
            }
          }
          if browser.page.phase == .loading {
            ProgressView(value: browser.progress).tint(accent).accessibilityLabel(
              "Loading recipe website"
            )
            .accessibilityValue("\(Int(browser.progress * 100)) percent")
          }
          ZStack {
            RecipeBrowserWebContent(controller: browser, initialURL: initialURL, surface: surface)
              .allowsHitTesting(!importing && browser.page.phase != .failed)
              .accessibilityHidden(browser.page.phase == .empty || browser.page.phase == .failed)
            if browser.page.phase == .empty || browser.page.phase == .failed { pageStateCard }
          }.frame(maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          RecipeBrowserChrome(maximumHeight: geometry.size.height * 0.35) { controls }
        }
      }
      .background(session.themeBgColor).foregroundStyle(session.themeTextColor)
      .navigationTitle("Recipe Browser").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { if importing { confirmClose = true } else { dismiss() } }
        }
        ToolbarItem(placement: .topBarTrailing) { pageMenu }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { addressFocused = false }
        }
      }
      .confirmationDialog(
        "Cancel this import?", isPresented: $confirmClose, titleVisibility: .visible
      ) {
        Button("Keep importing", role: .cancel) {}
        Button("Cancel import and close", role: .destructive) {
          cancelImport()
          dismiss()
        }
      } message: {
        Text("Nothing has been saved yet.")
      }
      .confirmationDialog(
        "Already in My Collection", isPresented: $showDuplicate, titleVisibility: .visible
      ) {
        Button("Open saved recipe") {
          imported = duplicate
          pendingDuplicate = nil
          showImported = true
        }
        Button("Review another copy") {
          draft = pendingDuplicate
          pendingDuplicate = nil
        }
        Button("Keep browsing", role: .cancel) { pendingDuplicate = nil }
      } message: {
        Text("You’ve already saved this source recipe. Your saved version won’t be overwritten.")
      }
      .sheet(item: $draft, onDismiss: { if imported != nil { showImported = true } }) { value in
        CreateRecipeView(
          prefill: value.form, prefillSource: value.source, allowAIStructuring: false,
          onSaved: {
            imported = $0
            AppAnalytics.shared.log(.recipeImported)
          }
        ).environment(session)
      }
      .navigationDestination(isPresented: $showImported) {
        if let imported { UserRecipeDetailView(recipe: imported).environment(session) }
      }
      .onChange(of: browser.address) { _, value in if !addressFocused { addressText = value } }
      .onChange(of: addressFocused) { _, focused in if focused { addressText = browser.address } }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background {
          browser.pause()
          cancelImport()
        }
      }
      .onDisappear {
        cancelImport()
        browser.webView?.pauseAllMediaPlayback(completionHandler: nil)
      }
      .interactiveDismissDisabled(importing)
      .qaScreen("Recipe Browser")
    }.stockedPresentationSurface(width: .full)
  }
  private var addressBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 6) {
        Image(systemName: "globe").accessibilityHidden(true)
        TextField("Recipe website or link", text: $addressText)
          .font(.stocked(.body)).textInputAutocapitalization(.never).autocorrectionDisabled()
          .keyboardType(.URL).submitLabel(.go).focused($addressFocused).onSubmit { openAddress() }
          .textFieldStyle(.plain).accessibilityLabel("Recipe website address")
          .accessibilityHint("Enter or paste a recipe link, then choose Go.")
        Button("Go", action: openAddress).frame(minWidth: 44, minHeight: 44).disabled(
          addressText.isEmpty)
      }.padding(.horizontal, 12).padding(.vertical, 4).background(
        surface, in: RoundedRectangle(cornerRadius: 16))
      if !browser.title.isEmpty || browser.currentURL != nil {
        VStack(alignment: .leading, spacing: 2) {
          if !browser.title.isEmpty {
            Text(browser.title).font(.stocked(.caption)).fixedSize(
              horizontal: false, vertical: true)
          }
          Text(RecipeBrowserPolicy.hostLabel(browser.currentURL)).font(.stocked(.caption))
            .fontWeight(.semibold)
        }.foregroundStyle(session.themeSecondaryText).accessibilityElement(children: .combine)
      }
    }.padding(.horizontal, 12).padding(.vertical, 8).disabled(importing)
  }
  private var pageStateCard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Image(systemName: browser.page.phase == .empty ? "book.closed" : "exclamationmark.circle")
          .font(.stocked(.largeTitle)).foregroundStyle(accent).accessibilityHidden(true)
        Text(browser.page.phase == .empty ? "Recipes from the web" : "Let’s try that again")
          .font(.stockedSerif(28, weight: .bold, relativeTo: .title)).accessibilityAddTraits(
            .isHeader)
        Text(
          browser.page.message
            ?? "Open a recipe link, explore the publisher’s website, then bring a recipe into your kitchen."
        ).font(.stocked(.body))
        if browser.page.phase == .empty {
          PasteButton(payloadType: String.self) { values in paste(values) }.tint(accent)
            .accessibilityLabel("Paste recipe website link")
          Text(
            "Browsing doesn’t save recipes. Website data stays in this temporary browser session."
          )
          .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        } else {
          Button("Try again") { browser.retry() }.frame(minHeight: 44).buttonStyle(
            .borderedProminent
          ).tint(.stockedCharcoal)
          if let url = browser.currentURL {
            Button("Open in your browser") { openURL(url) }.frame(minHeight: 44)
          }
        }
      }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
    }.background(surface)
  }
  private var controls: some View {
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        icon("chevron.left", label: "Back") { browser.back() }.disabled(
          !browser.canGoBack || importing)
        icon("chevron.right", label: "Forward") { browser.forward() }.disabled(
          !browser.canGoForward || importing)
        icon(
          browser.page.phase == .loading ? "xmark" : "arrow.clockwise",
          label: browser.page.phase == .loading ? "Stop loading" : "Reload page"
        ) {
          if browser.page.phase == .loading { browser.stop() } else { browser.retry() }
        }.disabled(browser.currentURL == nil || importing)
        Spacer(minLength: 0)
        PasteButton(payloadType: String.self) { values in paste(values) }.labelStyle(.iconOnly)
          .tint(accent)
          .frame(minWidth: 44, minHeight: 44).disabled(importing).accessibilityLabel(
            "Paste recipe website link")
      }
      Button(importing ? "Cancel import" : "Import this page") {
        if importing { cancelImport() } else { startImport() }
      }
      .font(.stocked(.headline)).frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 4)
      .foregroundStyle(Color.stockedWhite).background(
        Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 16)
      )
      .disabled(!importing && browser.page.importURL == nil)
      .accessibilityHint("Opens an editable recipe review. Nothing is saved automatically.")
      Text("Review before saving · Source credited · Rights stay with the publisher")
        .font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText).padding(.top, 4)
    }.padding(.horizontal, 12).padding(.vertical, 8).background(session.themeBgColor)
  }
  private var pageMenu: some View {
    Menu {
      Button("Find on page", systemImage: "magnifyingglass") {
        addressFocused = false
        browser.findInPage()
      }.disabled(browser.page.importURL == nil)
      Button("Jump to recipe", systemImage: "arrow.down.to.line") {
        addressFocused = false
        browser.jumpToRecipe()
      }.disabled(browser.page.importURL == nil)
      Menu("Page size: \(Int((browser.zoom * 100).rounded()))%", systemImage: "textformat.size") {
        Button("Larger text") { browser.setZoom(browser.zoom + 0.1) }.disabled(browser.zoom >= 1.6)
        Button("Smaller text") { browser.setZoom(browser.zoom - 0.1) }.disabled(browser.zoom <= 0.8)
        Button("Reset to 100%") { browser.setZoom(1) }
      }
      if !browser.history.isEmpty {
        Menu("Recent pages", systemImage: "clock") {
          ForEach(Array(browser.history.enumerated()), id: \.offset) { _, item in
            Button(item.title ?? RecipeBrowserPolicy.hostLabel(item.url)) { browser.go(to: item) }
          }
        }
      }
      if let url = browser.currentURL {
        Button("Open in your browser", systemImage: "safari") { openURL(url) }
        ShareLink(item: RecipeBrowserPolicy.importURL(url.absoluteString) ?? url) {
          Label("Share recipe link", systemImage: "square.and.arrow.up")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
    }
    .disabled(importing).accessibilityLabel("Recipe browser page options")
  }
  private func icon(_ image: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: image).frame(width: 44, height: 44) }
      .accessibilityLabel(label)
  }
  private func messageRow(_ text: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top) {
      Text(text).font(.stocked(.footnote)).frame(maxWidth: .infinity, alignment: .leading)
      icon("xmark", label: "Dismiss message", action: dismiss)
    }.padding(12).background(surface)
  }
  private func importFailure(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      messageRow(message) { importError = nil }
      HStack {
        Button("Retry import", action: startImport).frame(minHeight: 44)
        if let url = browser.currentURL {
          Button("View original") { openURL(url) }.frame(minHeight: 44)
        }
      }.font(.stocked(.body)).padding(.horizontal, 12)
    }.background(surface)
  }
  private func paste(_ values: [String]) {
    guard let first = values.first,
      let value = RecipeImportCoordinator.normalizedURLString(from: first)
    else {
      browser.notice = "The pasted text doesn’t contain a supported recipe link."
      return
    }
    addressText = value
    openAddress()
  }
  private func openAddress() {
    addressFocused = false
    importError = nil
    browser.open(addressText)
  }
  private func cancelImport() {
    guard importing else { return }
    importState.cancel()
    importTask?.cancel()
    importTask = nil
    stage = "Import cancelled"
    QARecorder.shared.record(.note, screen: "Recipe Import", label: "Import cancelled")
    announceAccessibilityStatus(stage)
  }
  private func startImport() {
    guard !importing, let url = browser.page.importURL else { return }
    addressFocused = false
    importError = nil
    imported = nil
    pendingDuplicate = nil
    stage = "Reading this page…"
    QARecorder.shared.record(.note, screen: "Recipe Import", label: "Import started")
    let token = importState.begin()
    importTask = Task { @MainActor in
      defer { importState.finish(token) }
      do {
        let snapshot = await browser.renderedPage()
        try Task.checkCancellation()
        let result: RecipeImportCoordinator.Result
        if let snapshot,
          let parsed = await RecipeImportCoordinator.parsePage(
            html: snapshot.html, url: snapshot.url, allowTextFallback: false)
        {
          result = parsed
        } else {
          guard ConnectivityMonitor.isOnlineFlag else {
            throw RecipePageLoadError(
              message:
                "This page has no readable recipe metadata. Reconnect to import, or keep viewing the original."
            )
          }
          result = try await RecipeImportCoordinator.importURL(url.absoluteString) {
            if importState.accepts(token) { stage = $0 }
          }
        }
        try Task.checkCancellation()
        guard importState.accepts(token) else { return }
        guard RecipeBrowserPolicy.sameDocument(browser.page.importURL, url) else {
          throw RecipePageLoadError(
            message:
              "The website navigated to another page during import. Check the current page and try again."
          )
        }
        var form = result.form
        if form.sourceURL.isEmpty { form.sourceURL = url.absoluteString }
        form.notes = [form.notes, RecipeImportQuality.summary(form)].filter { !$0.isEmpty }.joined(
          separator: "\n")
        let value = Draft(form: form, source: result.source)
        if let existing = RecipeImportQuality.exactDuplicate(
          form, in: session.guestStore.userRecipes)
        {
          duplicate = existing
          pendingDuplicate = value
          showDuplicate = true
        } else {
          var reviewed = value
          if let similar = RecipeImportQuality.duplicate(form, in: session.guestStore.userRecipes) {
            reviewed.form.notes =
              "A saved recipe has a similar title: ‘\(similar.title)’. Review before saving.\n"
              + form.notes
          }
          draft = reviewed
        }
        announceAccessibilityStatus(
          "Recipe ready to review. \(form.ingredients.count) ingredients and \(form.steps.count) steps."
        )
        QARecorder.shared.record(
          .success, screen: "Recipe Import", label: "Import ready for review",
          detail:
            "\(form.ingredients.count) ingredients; \(form.steps.count) steps; duplicate review: \(showDuplicate)"
        )
      } catch is CancellationError {} catch {
        guard importState.accepts(token) else { return }
        importError =
          (error as? RecipePageLoadError)?.message
          ?? "We couldn’t extract this recipe. Open the individual recipe page, or use text/screenshot import. You can always view the original."
        announceAccessibilityStatus(importError ?? "Import failed")
        QARecorder.shared.record(
          .failure, screen: "Recipe Import", label: "Import failed",
          detail: "View original remains available")
      }
    }
  }
}

/// Shared source-link action for saved, catalogue and website recipe detail surfaces.
struct RecipeBrowserLink: View {
  var url: String
  var title = "View original recipe"
  @State private var showing = false
  var body: some View {
    if let target = RecipeBrowserPolicy.url(url) {
      Button {
        showing = true
      } label: {
        Label(title, systemImage: "safari").frame(minHeight: 44)
      }
      .sheet(isPresented: $showing) { RecipeBrowserView(initialURL: target) }
    }
  }
}
