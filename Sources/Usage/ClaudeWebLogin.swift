import AppKit
import CryptoKit
import Foundation
import Network

/// In-app Claude Code login using the same PKCE + loopback-callback flow the
/// `claude` CLI uses for a local sign-in. We open the real authorize page in
/// the user's default browser (so their existing claude.ai session is reused —
/// usually one click), and catch the OAuth redirect on a short-lived local
/// HTTP server, so the whole thing completes without a Terminal window and
/// without the user copy-pasting a code back. On success the fresh, fully-scoped
/// token pair is written to the `Claude Code-credentials` keychain item via
/// `ClaudeCredentials`, which is exactly what a `claude /login` would have done.
///
/// Why this exists: the previous re-auth spawned `claude auth login` in Terminal,
/// which blocks on an interactive "Paste code here" prompt (its browser callback
/// lands on a platform.claude.com web page, not a localhost listener), so it
/// never completed unattended and the usage tile stayed stuck. This flow removes
/// the paste step entirely by owning the loopback listener ourselves.
/// `@unchecked Sendable`: every mutable field is only ever touched on `queue`
/// (the listener callbacks, the timeout, and the single continuation resume all
/// run there), so the type is thread-safe by construction even though the
/// compiler can't prove it.
final class ClaudeWebLogin: @unchecked Sendable {
    static let shared = ClaudeWebLogin()

    enum Outcome {
        case success
        case failed(String)
        case canceled
    }

    /// All listener callbacks, timeout, and the single continuation resume are
    /// serialized on this queue, so a plain `finished` flag is enough to
    /// guarantee we resume exactly once.
    private let queue = DispatchQueue(label: "dev.agentisland.claude-web-login")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished = false
    private var verifier = ""
    private var state = ""
    private var redirectURI = ""
    private var timeout: DispatchWorkItem?

    /// How the authorize URL reaches the user once the listener is up.
    enum Delivery {
        case open
        case copyLink
    }

    private var delivery: Delivery = .open

    /// Runs the full flow and resolves once the browser round-trip completes,
    /// times out (~3 min), or fails to start. Safe to call again afterwards.
    /// `.copyLink` puts the URL on the clipboard instead of opening it, for
    /// accounts that live in a browser we can't target.
    func start(delivery: Delivery = .open) async -> Outcome {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                self?.delivery = delivery
                self?.begin(cont)
            }
        }
    }

    /// The CLI's manual path: the authorize page redirects to
    /// platform.claude.com, which shows `code#state` for the user to paste
    /// back. Needs no local listener, so it works where loopback is blocked.
    @MainActor
    func startWithCode() async -> Outcome {
        let verifier = Self.randomURLSafe(32)
        let state = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let redirect = ClaudeCredentials.manualRedirectURI
        guard let url = Self.authorizeURL(challenge: challenge, state: state, redirectURI: redirect) else {
            return .failed("bad authorize URL")
        }
        ClaudeSignInBrowser.current.open(url)

        var hint = L10n.tr("Approve the page that just opened, then paste the code it shows here")
        while true {
            guard let pasted = Self.promptForCode(message: hint) else { return .canceled }
            let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
            guard parts.count == 2, String(parts[1]) == state else {
                hint = L10n.tr("Copy the whole code from the page and try once more")
                continue
            }
            let ok = await ClaudeCredentials.completeWebLogin(
                code: String(parts[0]), codeVerifier: verifier, redirectURI: redirect, state: state
            )
            if ok {
                NSApp.activate(ignoringOtherApps: true)
                return .success
            }
            hint = L10n.tr("That code did not work")
        }
    }

    @MainActor
    private static func promptForCode(message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Sign in with a code")
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Sign in"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - Flow

    private func begin(_ cont: CheckedContinuation<Outcome, Never>) {
        finished = false
        continuation = cont
        verifier = Self.randomURLSafe(32)
        state = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            finish(.failed("could not open local callback server"))
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener?.port?.rawValue else {
                    self.finish(.failed("no callback port"))
                    return
                }
                self.redirectURI = "http://localhost:\(port)/callback"
                self.openAuthorizePage(challenge: challenge)
                self.armTimeout()
            case .failed(let error):
                self.finish(.failed("callback server failed: \(error)"))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func openAuthorizePage(challenge: String) {
        guard let url = Self.authorizeURL(challenge: challenge, state: state, redirectURI: redirectURI) else {
            finish(.failed("bad authorize URL"))
            return
        }
        let delivery = self.delivery
        DispatchQueue.main.async {
            switch delivery {
            case .open:
                ClaudeSignInBrowser.current.open(url)
            case .copyLink:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    /// Mirrors the `claude` CLI's authorize URL exactly (param set + 32-byte
    /// state); claude.ai rejects deviations with "Invalid request format".
    private static func authorizeURL(challenge: String, state: String, redirectURI: String) -> URL? {
        guard var comps = URLComponents(string: ClaudeCredentials.authorizeURLBase) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeCredentials.oauthClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ClaudeCredentials.loginScopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url
    }

    private func armTimeout() {
        let item = DispatchWorkItem { [weak self] in self?.finish(.failed("login timed out")) }
        timeout = item
        queue.asyncAfter(deadline: .now() + 180, execute: item)
    }

    // MARK: - Callback

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first,
                  let rawPath = requestLine.split(separator: " ").dropFirst().first,
                  let comps = URLComponents(string: "http://localhost\(rawPath)"),
                  comps.path == "/callback" else {
                // Favicon or an unrelated probe — answer politely, keep waiting.
                self.send(conn, ok: false)
                return
            }
            let items = comps.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

            if let error = value("error") {
                self.send(conn, ok: false)
                self.finish(.failed(error))
                return
            }
            guard let code = value("code"), value("state") == self.state else {
                self.send(conn, ok: false)
                self.finish(.failed("state mismatch"))
                return
            }

            Task {
                let ok = await ClaudeCredentials.completeWebLogin(
                    code: code,
                    codeVerifier: self.verifier,
                    redirectURI: self.redirectURI,
                    state: self.state
                )
                self.send(conn, ok: ok)
                if ok {
                    DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
                    self.finish(.success)
                } else {
                    self.finish(.failed("token exchange failed"))
                }
            }
        }
    }

    private func send(_ conn: NWConnection, ok: Bool) {
        let emoji = ok ? "✅" : "⚠️"
        let title = ok ? "已连接 Claude" : "登录未完成"
        let note = ok ? "认证成功，可以关闭此页并返回 Gauge。" : "请回到 Gauge 重试。"
        let body = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Agent Island</title></head>\
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        background:#0b0f0e;color:#e8f0ee;font-family:-apple-system,system-ui,sans-serif">\
        <div style="text-align:center"><div style="font-size:46px;margin-bottom:14px">\(emoji)</div>\
        <div style="font-size:19px;font-weight:600">\(title)</div>\
        <div style="margin-top:8px;color:#8a9a95">\(note)</div></div></body></html>
        """
        let http = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    func cancel() {
        finish(.canceled)
    }

    private func finish(_ outcome: Outcome) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.timeout?.cancel()
            self.timeout = nil
            self.listener?.cancel()
            self.listener = nil
            let cont = self.continuation
            self.continuation = nil
            cont?.resume(returning: outcome)
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: bytes)
        for index in 0..<bytes { data[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
