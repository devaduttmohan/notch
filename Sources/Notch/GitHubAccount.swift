import AppKit
import SwiftUI

/// Your GitHub sign-in, as gh has it: the accounts signed in on github.com, which one is
/// active (Notch and your terminal share it), and gh's browser sign-in, driven from the
/// customiser. Notch never sees a token: gh keeps it in the keychain.
@MainActor final class GitHubAccount: ObservableObject {
    struct Account: Equatable, Identifiable {
        var login: String
        var active: Bool
        var ok: Bool                 // false: gh has it, but the token stopped working
        var source: String           // "keyring", "GH_TOKEN"…
        var id: String { login }
    }

    struct Profile: Equatable {
        var login: String
        var name: String?
        var avatar: URL?
    }

    enum Phase: Equatable {
        case checking
        case noCLI
        case signedOut
        /// gh's device flow: a one-time code to enter at github.com/login/device.
        case signingIn(code: String?, url: URL?)
        case signedIn
        case failed(String)
    }

    @Published var phase: Phase = .checking
    @Published var accounts: [Account] = []
    @Published var profile: Profile?
    /// Why the last sign-in didn't finish, shown under the account until the next try.
    @Published var notice: String?
    var active: Account? { accounts.first { $0.active } }
    /// The active account changed (signed in, switched): look at its pull requests now.
    var onChange: (() -> Void)?

    nonisolated static let host = "github.com"
    nonisolated static let deviceURL = URL(string: "https://github.com/login/device")!
    private var signInProcess: Process?
    private var cancelled = false

    /// Ask gh who's signed in (no GraphQL points; the profile is one REST call, once per account).
    func load(then done: (() -> Void)? = nil) {
        guard let gh = PRWatcher.ghPath else {
            phase = .noCLI
            return
        }
        if case .signingIn = phase { return }
        Self.runAsync(gh, ["auth", "status", "--hostname", Self.host, "--json", "hosts"]) { [weak self] _, data in
            guard let self else { return }
            let accounts = Self.parseStatus(data)
            withAnimation(UISpring.soft) {
                self.accounts = accounts
                if let active = self.active {
                    self.phase = active.ok ? .signedIn : .failed("gh's sign-in for @\(active.login) stopped working. Sign in again.")
                } else {
                    self.phase = .signedOut
                    self.profile = nil
                }
            }
            if let active = self.active, active.ok, self.profile?.login != active.login { self.loadProfile(gh, login: active.login) }
            done?()
        }
    }

    /// gh's browser sign-in: it hands out a one-time code, you enter it on github.com, and gh
    /// stores the token. Signing in to another account makes it the active one (in your
    /// terminal too).
    func signIn() {
        guard let gh = PRWatcher.ghPath else {
            phase = .noCLI
            return
        }
        signInProcess?.terminate()
        cancelled = false
        withAnimation(UISpring.soft) {
            notice = nil
            phase = .signingIn(code: nil, url: nil)
        }
        log("github: signing in through gh (in the browser)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "login", "--hostname", Self.host, "--web", "--skip-ssh-key"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let prompt = Self.parseSignIn(output.append(chunk))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(prompt) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = ended.terminationStatus
            let text = output.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.signInEnded(status: status, output: text) }
            }
        }
        do {
            try process.run()
            signInProcess = process
        } catch {
            withAnimation(UISpring.soft) { phase = .failed("Couldn't start gh: \(error.localizedDescription)") }
        }
    }

    func cancelSignIn() {
        cancelled = true
        signInProcess?.terminate()
    }

    /// Copies the code and opens GitHub's device page, where it gets pasted.
    func copyCodeAndOpen() {
        guard case .signingIn(let code?, let url) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSWorkspace.shared.open(url ?? Self.deviceURL)
    }

    /// Makes another signed-in account the active one (for gh everywhere, not only Notch).
    func switchTo(_ login: String) {
        guard let gh = PRWatcher.ghPath else { return }
        Self.runAsync(gh, ["auth", "switch", "--hostname", Self.host, "--user", login]) { [weak self] status, _ in
            log(status == 0 ? "github: switched to @\(login)" : "github: couldn't switch to @\(login) (gh exit \(status))")
            self?.load { self?.onChange?() }
        }
    }

    private func received(_ prompt: (code: String?, url: URL?)) {
        guard case .signingIn(let code, let url) = phase, prompt.code != code || prompt.url != url else { return }
        withAnimation(UISpring.soft) { phase = .signingIn(code: prompt.code ?? code, url: prompt.url ?? url) }
    }

    private func signInEnded(status: Int32, output: String) {
        signInProcess = nil
        if cancelled || status == 0 {
            if status == 0 { log("github: signed in through gh") }
            withAnimation(UISpring.soft) { phase = .checking }
            load { [weak self] in if status == 0 { self?.onChange?() } }
            return
        }
        let last = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.contains("one-time code") }
        log("github: sign-in didn't finish (gh exit \(status))")
        withAnimation(UISpring.soft) {
            notice = last.map { "Sign-in didn't finish: \($0)" } ?? "Sign-in didn't finish."
            phase = .checking
        }
        load()
    }

    private func loadProfile(_ gh: String, login: String) {
        Self.runAsync(gh, ["api", "user"]) { [weak self] status, data in
            guard let self, status == 0,
                  let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (user["login"] as? String)?.lowercased() == login.lowercased() else { return }
            let name = (user["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let avatar = (user["avatar_url"] as? String).flatMap { URL(string: $0 + ($0.contains("?") ? "&" : "?") + "s=96") }
            withAnimation(UISpring.soft) { self.profile = Profile(login: login, name: name, avatar: avatar) }
        }
    }

    // MARK: Reading gh

    /// `gh auth status --json hosts`: every account gh holds for github.com.
    nonisolated static func parseStatus(_ data: Data) -> [Account] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = root["hosts"] as? [String: Any],
              let list = hosts[host] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let login = entry["login"] as? String, !login.isEmpty else { return nil }
            return Account(login: login, active: entry["active"] as? Bool ?? false,
                           ok: entry["state"] as? String == "success", source: entry["tokenSource"] as? String ?? "")
        }
    }

    /// "! First copy your one-time code: AB12-CD34" and "…web browser: https://github.com/login/device".
    nonisolated static func parseSignIn(_ text: String) -> (code: String?, url: URL?) {
        let code = text.range(of: #"code: [A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression)
            .map { String(text[$0].dropFirst("code: ".count)) }
        let url = text.range(of: #"https://\S+"#, options: .regularExpression).flatMap { URL(string: String(text[$0])) }
        return (code, url)
    }

    private static func runAsync(_ gh: String, _ arguments: [String],
                                 then done: @escaping @MainActor (Int32, Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PRWatcher.run(gh, arguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(result.status, result.output) }
            }
        }
    }
}

/// Output gathered from a running process, read from its pipe's queue.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        return String(decoding: data, as: UTF8.self)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
