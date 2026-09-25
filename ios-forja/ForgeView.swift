/*  ForgeView.swift — the app's one surface: La Forja's real engine in a WKWebView, plus the native
    things a web page cannot do for itself. Structure ported from Bitácora's LogbookView.swift.

    WHY A CUSTOM SCHEME. The log lives in localStorage, so the ORIGIN is the key the data is filed
    under. file:// is the odd child of every WebKit storage migration, and a localhost server ties
    the log to a port number (a changed port is a different origin: the data is simply gone). A
    registered scheme handler gives a stable, port-free origin in the ordinary website data store.

    The webview holds no credentials of its own: the GitHub token and Anthropic key live where they
    always did, in the app's settings in localStorage — per device, so they are entered once here. */
import SwiftUI
import WebKit
import UIKit
import UserNotifications

// MARK: - Serving the bundle

final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "forja-app"
    static let root = "local"

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "ttf": "font/ttf", "json": "application/json; charset=utf-8",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "svg": "image/svg+xml",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }
        guard !path.contains(".."), let base = Bundle.main.url(forResource: "app", withExtension: nil)
        else { return task.didFailWithError(URLError(.badURL)) }
        let file = base.appendingPathComponent(path)
        guard file.path.hasPrefix(base.path), let data = try? Data(contentsOf: file) else {
            Vault.shared.log("404 \(path)")        // a blank screen has too many causes; this names one
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(r); task.didReceive(Data("not in bundle: \(path)".utf8)); task.didFinish()
            return
        }
        let mime = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Cache-Control": "no-cache"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - The live workout: rest notification + keep-awake

/*  Read from every save (the page saves on each stepper tap and every timer change). Only a CHANGE
    in the pending end-time touches the notification centre; a past or missing end-time cancels and
    never schedules — which is also what makes a stale endsAt after a reload harmless. */
final class WorkoutWatcher {
    static let shared = WorkoutWatcher()
    private var lastEnds: Double? = -1
    private var asked = false
    private let center = UNUserNotificationCenter.current()
    private let ident = "forja.rest"

    func observe(_ obj: [String: Any]) {
        let aw = obj["activeWorkout"] as? [String: Any]
        // The screen stays lit for the whole workout — a phone that sleeps mid-rest hides the timer.
        let awake = aw != nil
        if UIApplication.shared.isIdleTimerDisabled != awake { UIApplication.shared.isIdleTimerDisabled = awake }

        let rest = (aw?["rest"] as? [String: Any])?["endsAt"] as? Double
        let hold = (aw?["hold"] as? [String: Any])?["endsAt"] as? Double
        let ends = hold ?? rest
        if ends == lastEnds { return }
        lastEnds = ends
        center.removePendingNotificationRequests(withIdentifiers: [ident])
        guard let ends else { return }
        let wait = ends / 1000 - Date().timeIntervalSince1970
        guard wait > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = hold != nil ? "Hold's done" : "Rest's over"
        content.body = nextUp(obj, aw) ?? "Back in the fire."
        content.sound = .default
        let req = UNNotificationRequest(identifier: ident, content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
        let add = { self.center.add(req) { err in if let err { Vault.shared.log("notify add: \(err.localizedDescription)") } } }
        if asked { return add() }
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            self.asked = true
            if ok { add() } else { Vault.shared.log("notifications declined — rest end will not buzz while locked") }
        }
    }

    /// "Dumbbell Curl — set 3 of 4", from the runner's cursor. nil when anything is missing.
    private func nextUp(_ obj: [String: Any], _ aw: [String: Any]?) -> String? {
        guard let cur = aw?["cursor"] as? [String: Any], let xi = cur["xi"] as? Int, let ri = cur["ri"] as? Int,
              let wxs = aw?["exercises"] as? [[String: Any]], xi < wxs.count,
              let exId = wxs[xi]["exerciseId"] as? String,
              let ex = (obj["exercises"] as? [[String: Any]])?.first(where: { ($0["id"] as? String) == exId }),
              let name = ex["name"] as? String else { return nil }
        let n = (wxs[xi]["rows"] as? [Any])?.count ?? 0
        return n > 0 ? "\(name) — set \(ri + 1) of \(n)" : name
    }
}

// MARK: - The bridge

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView? { didSet { speech.webView = webView } }
    let speech = SpeechBridge()

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let selection = UISelectionFeedbackGenerator()
    private let notice = UINotificationFeedbackGenerator()

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "save":   handleSave(body["json"] as? String)
        case "haptic": handleHaptic(body["kind"] as? String ?? "light")
        case "speech": speech.handle(body)
        case "ready":  Vault.shared.log("page ready")
        case "log":    Vault.shared.log("page: \(body["text"] as? String ?? "")")
        default: break
        }
    }

    private func handleSave(_ json: String?) {
        guard let json, let data = json.data(using: .utf8) else { return }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { WorkoutWatcher.shared.observe(obj) }
        switch Vault.shared.offer(data) {
        case .accepted, .heldStale: break
        case .heldShrink(let was, let now):
            notice.notificationOccurred(.warning)
            toPage("shrink", "\(was) logged sets to \(now)")
            askAboutShrink(was: was, now: now)
        case .rejectedInvalid:
            notice.notificationOccurred(.error)
            toPage("invalid", "")
        }
    }

    private func toPage(_ kind: String, _ detail: String) {
        let esc = detail.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.__forjaVaultNotice && window.__forjaVaultNotice('\(kind)','\(esc)')")
    }

    /// A held save is a question for a human, asked natively so it can't hide behind a toast, and
    /// phrased so that doing nothing is the safe answer.
    private func askAboutShrink(was: Int, now: Int) {
        guard let vc = Self.topViewController(), !(vc is UIAlertController) else { return }
        let a = UIAlertController(
            title: "Backup held",
            message: "This save drops your log from \(was) sets to \(now). Your backup still has all \(was).\n\nIf you deleted them on purpose, keep the change. If not, the backup is untouched — reopen the app to restore it.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Keep backup", style: .cancel))
        a.addAction(UIAlertAction(title: "I deleted them", style: .destructive) { _ in _ = Vault.shared.promotePending() })
        vc.present(a, animated: true)
    }

    private func handleHaptic(_ kind: String) {
        switch kind {
        case "selection": selection.selectionChanged()
        case "medium":    medium.impactOccurred()
        case "success":   notice.notificationOccurred(.success)
        case "warning":   notice.notificationOccurred(.warning)
        default:          light.impactOccurred()
        }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

// MARK: - The view

struct ForgeView: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        cfg.websiteDataStore = .default()                 // persistent; NOT .nonPersistent()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        /*  The vault, injected synchronously at document-start — it must be in place before
            index.html's script reads localStorage. Base64 with an explicit UTF-8 decode, NOT
            JSON.parse(atob(...)): atob yields bytes, and reading them as characters would mangle
            every accent in his debriefs, which are half in Spanish. */
        if let json = Vault.shared.primaryJSON(), let b64 = json.data(using: .utf8)?.base64EncodedString() {
            let s = Vault.shared.currentSummary()
            let src = """
            (function () {
              try {
                var bin = atob('\(b64)');
                var bytes = new Uint8Array(bin.length);
                for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                window.__FORJA_VAULT__ = { json: new TextDecoder('utf-8').decode(bytes), lastModified: \(Int(s?.lastModified ?? 0)), sets: \(s?.itemCount ?? 0) };
              } catch (e) { window.__FORJA_VAULT__ = null; }
            })();
            """
            cfg.userContentController.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        cfg.userContentController.add(context.coordinator, name: "forja")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.webView = wv
        wv.scrollView.contentInsetAdjustmentBehavior = .never   // the page positions itself from env(safe-area-*)
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0x17 / 255.0, green: 0x12 / 255.0, blue: 0x0f / 255.0, alpha: 1)   // --bg soot
        wv.scrollView.backgroundColor = .clear
        #if DEBUG
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        #endif
        var start = "\(BundleSchemeHandler.scheme)://\(BundleSchemeHandler.root)/index.html"
        #if DEBUG
        // simctl launch com.leandro.forja -route exercises → opens that screen (the page's own #/ router).
        // Debug builds only: it lets the simulator be checked screen by screen without a tap driver.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-route"), i + 1 < args.count { start += "#/" + args[i + 1] }
        #endif
        wv.load(URLRequest(url: URL(string: start)!))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
