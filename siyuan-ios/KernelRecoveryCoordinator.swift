import Foundation

// Pure protocol state is compiled and tested on the host as well as iOS.
struct KernelRecoveryState {
  struct Event {
    let requestID: Int64
    let generation: Int64
    let state: String
    let detail: String
  }
  private(set) var scenes = Set<String>()
  private var lifecycleActive: Bool?
  private(set) var desired: Bool?
  private(set) var requestID: Int64 = 0
  private(set) var latest: Event?
  private(set) var pageID: String?
  private(set) var navigation = 0
  private(set) var frontendConnected = false
  private(set) var recoveryCompleted = false
  private var initialTransportPending = false

  mutating func requestInitialTransport() { initialTransportPending = true }

  mutating func takeInitialTransport() -> Bool {
    guard initialTransportPending, desired == true,
      latest?.requestID == requestID, latest?.state == "TransportAccepting" else { return false }
    initialTransportPending = false
    return true
  }

  // Foundation URL.path normalizes the trailing slash of a directory URL.
  static func isTrustedURL(_ url: URL?, port: Int) -> Bool {
    guard let url = url, port > 0 else { return false }
    let paths = ["/stage/build/mobile", "/stage/build/desktop"]
    return url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
      && paths.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
  }

  mutating func scene(_ id: String, foreground: Bool) -> (Bool, Int64)? {
    var current = scenes
    if foreground { current.insert(id) } else { current.remove(id) }
    return replaceScenes(current)
  }

  mutating func replaceScenes(_ current: Set<String>) -> (Bool, Int64)? {
    scenes = current
    let active = !scenes.isEmpty
    guard lifecycleActive != active else { return nil }
    lifecycleActive = active
    return command(active)
  }

  mutating func command(_ active: Bool) -> (Bool, Int64) {
    desired = active
    requestID += 1
    frontendConnected = false
    recoveryCompleted = false
    return (active, requestID)
  }

  mutating func receive(_ event: Event) -> Bool {
    guard event.requestID == requestID,
      event.generation >= (latest?.generation ?? 0), event.state != "Cancelled" else { return false }
    latest = event
    return true
  }

  mutating func invalidatePage() {
    navigation += 1
    pageID = nil
    frontendConnected = false
    recoveryCompleted = false
  }

  mutating func bridgeReady(_ page: String, navigation expected: Int) -> Bool {
    guard expected == navigation else { return false }
    pageID = page
    return true
  }

  mutating func acknowledge(_ kind: String, page: String, request: Int64, generation: Int64) -> Bool {
    guard ["frontendConnected", "recoveryCompleted", "frontendFailed"].contains(kind),
      page == pageID, request == requestID, generation == latest?.generation,
      latest?.state == "TransportAccepting" else { return false }
    if kind == "frontendConnected" { frontendConnected = true }
    if kind == "recoveryCompleted" && frontendConnected { recoveryCompleted = true }
    if kind == "frontendFailed" { frontendConnected = false; recoveryCompleted = false }
    return true
  }
}

#if canImport(UIKit) && canImport(Iosk)
import UIKit
import WebKit
import Iosk

private final class ServingObserver: NSObject, MobileServingObserverProtocol {
  weak var owner: KernelRecoveryCoordinator?
  func onServingEvent(_ requestID: Int64, generation: Int64, state: String?, detail: String?) {
    let event = KernelRecoveryState.Event(requestID: requestID, generation: generation,
      state: state ?? "Failed", detail: detail ?? "")
    DispatchQueue.main.async { [weak self] in self?.owner?.receive(event) }
  }
}

// One application-level coordinator owns the shared kernel and static WebView.
// Scene demand is aggregated; transient inactive states preserve the listener.
final class KernelRecoveryCoordinator: NSObject, WKScriptMessageHandler {
  static let shared = KernelRecoveryCoordinator()
  private var state = KernelRecoveryState()
  private weak var webView: WKWebView?
  private weak var pageOwner: AnyObject?
  private var observer: ServingObserver?
  private var retryPending = false
  private var installed = false
  private var initialLoad: (() -> Void)?
  private var sceneObservers: [NSObjectProtocol] = []
  private weak var failureAlert: UIAlertController?
  private(set) var deliveryFailure: String?

  func install(_ webView: WKWebView, owner: AnyObject) {
    pageOwner = owner
    guard !installed else { return }
    installed = true
    self.webView = webView
    webView.configuration.userContentController.add(self, name: "kernelRecovery")
    let observer = ServingObserver()
    observer.owner = self
    self.observer = observer
    MobileInstallServingObserver(observer)
    // 场景需求属于整个应用，页面 owner 更换时继续接收前后台事件。
    if sceneObservers.isEmpty {
      for (name, foreground) in [(UIScene.willEnterForegroundNotification, true),
                               (UIScene.didActivateNotification, true),
                               (UIScene.didEnterBackgroundNotification, false),
                               (UIScene.didDisconnectNotification, false)] {
        sceneObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
          guard let scene = notification.object as? UIScene else { return }
          self?.scene(scene, foreground: foreground)
        })
      }
    }
    refreshScenes()
  }

  func detach(_ webView: WKWebView, owner: AnyObject) {
    guard self.webView === webView, pageOwner === owner else { return }
    MobileInstallServingObserver(nil)
    observer?.owner = nil
    observer = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "kernelRecovery")
    self.webView = nil
    initialLoad = nil
    installed = false
    state.invalidatePage()
  }

  func scene(_ scene: UIScene, foreground: Bool) {
    if let command = state.scene(scene.session.persistentIdentifier, foreground: foreground) {
      retryPending = false
      send(command)
    }
  }

  func refreshScenes() {
    let current = Set(UIApplication.shared.connectedScenes.filter {
      $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
    }.map { $0.session.persistentIdentifier })
    if let command = state.replaceScenes(current) {
      retryPending = false
      send(command)
    }
  }

  private func send(_ command: (Bool, Int64)) {
    log("desired=\(command.0) request=\(command.1)")
    // Go only records intent here. Listen and connection cleanup run in Go's
    // worker; UIKit does not wait for a socket or a ready channel.
    MobileSetServingDesiredState(command.0, command.1)
  }

  func whenAccepting(_ action: @escaping () -> Void) {
    initialLoad = action
    state.requestInitialTransport()
    deliverInitialLoad()
  }

  private func deliverInitialLoad() {
    guard state.takeInitialTransport() else { return }
    let action = initialLoad
    initialLoad = nil
    log("initial_transport_accepting")
    action?()
  }

  func retry(_ message: WKScriptMessage) {
    guard trusted(message) else { return }
    retry()
  }

  private func retry() {
    guard !retryPending, !state.scenes.isEmpty else { return }
    retryPending = true
    send(state.command(false))
    send(state.command(true))
  }

  func invalidatePage(_ webView: WKWebView) {
    guard self.webView === webView else { return }
    state.invalidatePage()
  }

  func navigationFinished(_ webView: WKWebView) {
    guard self.webView === webView, trustedURL(webView.url) else { return }
    // Explicit navigation completion replays the handshake, including a failed
    // earlier JS injection. It never declares the WebSocket connected.
    webView.evaluateJavaScript("window.siyuanRecovery?.handshake()") { [weak self] _, error in
      if error != nil { self?.recordDeliveryFailure() }
    }
  }

  fileprivate func receive(_ event: KernelRecoveryState.Event) {
    guard installed, state.receive(event) else { return }
    if event.state == "TransportAccepting" || event.state == "Failed" || event.state == "Stopped" { retryPending = false }
    log("state=\(event.state) request=\(event.requestID) generation=\(event.generation)")
    deliverInitialLoad()
    if event.state == "Failed" { showFailure() }
    deliver()
  }

  private func deliver() {
    guard let webView = webView, trustedURL(webView.url), let page = state.pageID,
      let event = state.latest, event.requestID == state.requestID else { return }
    let payload: [String: Any] = ["pageID": page, "requestID": event.requestID,
      "generation": event.generation, "state": event.state, "detail": event.detail]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8) else { return }
    let navigation = state.navigation
    webView.evaluateJavaScript("window.siyuanRecovery?.receive(\(json))") { [weak self] _, error in
      guard let self = self, self.state.navigation == navigation else { return }
      if error != nil { self.recordDeliveryFailure() } else { self.deliveryFailure = nil }
    }
  }

  private func trustedURL(_ url: URL?) -> Bool {
    KernelRecoveryState.isTrustedURL(url, port: MobileServingPort())
  }

  private func trusted(_ message: WKScriptMessage) -> Bool {
    guard message.webView === webView, message.frameInfo.isMainFrame,
      trustedURL(message.frameInfo.request.url), trustedURL(webView?.url) else { return false }
    let origin = message.frameInfo.securityOrigin
    return origin.protocol == "http" && origin.host == "127.0.0.1" && origin.port == MobileServingPort()
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard trusted(message), let body = message.body as? [String: Any],
      let kind = body["kind"] as? String, let page = body["pageID"] as? String else { return }
    if kind == "bridgeReady" {
      guard body["protocolVersion"] as? Int == 1 else { return }
      let navigation = state.navigation
      // Reading current JS identity fences late bridgeReady messages from a
      // previous same-origin document, including queued native messages.
      webView?.evaluateJavaScript("window.siyuanRecovery?.pageID") { [weak self] actual, error in
        guard let self = self, error == nil, actual as? String == page,
          self.state.bridgeReady(page, navigation: navigation) else { return }
        self.log("bridgeReady page=\(page)")
        self.deliver()
      }
      return
    }
    guard page == state.pageID else { return }
    if kind == "retry" { retry(message); return }
    if kind == "cancel" { retryPending = false; send(state.command(false)); return }
    guard let request = body["requestID"] as? NSNumber,
      let generation = body["generation"] as? NSNumber else { return }
    if state.acknowledge(kind, page: page, request: request.int64Value, generation: generation.int64Value) {
      log("ack=\(kind) request=\(request) generation=\(generation)")
    }
  }

  private func recordDeliveryFailure() {
    deliveryFailure = "javascript_delivery_failed"
    log("javascript_delivery_failed")
    showFailure()
  }

  func exitKernel() {
    state.invalidatePage()
    DispatchQueue.global(qos: .userInitiated).async { MobileExitWithRecovery() }
  }

  private func showFailure() {
    guard failureAlert == nil, let root = webView?.window?.rootViewController else { return }
    var presenter = root
    while let presented = presenter.presentedViewController { presenter = presented }
    let alert = UIAlertController(title: "Connection recovery", message: "The connection could not be restored. Your page is preserved.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
      self?.retry()
      if let webView = self?.webView { self?.navigationFinished(webView) }
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
      guard let self = self else { return }
      self.retryPending = false
      self.send(self.state.command(false))
    })
    failureAlert = alert
    presenter.present(alert, animated: true)
  }

  private func log(_ message: String) {
    if UserDefaults.standard.bool(forKey: "iosRecoveryLogging")
      || Bundle.main.object(forInfoDictionaryKey: "SiYuanRecoveryDiagnostics") as? Bool == true {
      NSLog("[recovery] %@", message)
    }
  }
}
#endif
