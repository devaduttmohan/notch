import AppKit
import Darwin
import Foundation

/// A private local socket for alerts from `notchctl` (scripts, `notchctl run`, Claude Code
/// hooks). It's a Unix socket in ~/Library/Application Support/Notch/, a folder only your
/// user can open, and every connection is checked to come from your user. Nothing on the
/// network, and no other user on this Mac, can reach it.
///
/// Each connection sends one JSON object (a line), then closes.
@MainActor final class AlertServer {
    nonisolated static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notch/notch.sock").path
    }

    var onMessage: (([String: Any]) -> Void)?

    private var listenSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, data: Data)] = [:]

    func start() {
        let path = Self.socketPath
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path)                                     // a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return log("alerts: couldn't create socket (\(errno))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return log("alerts: socket path too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return log("alerts: couldn't listen on \(path) (\(errno))")
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenSocket = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptClients() }
        }
        source.resume()
        listenSource = source
        log("listening for notchctl on \(path)")
    }

    private func acceptClients() {
        while true {
            let client = accept(listenSocket, nil, nil)
            guard client >= 0 else { return }
            // Only this user. (The folder permissions already ensure it; belt and braces.)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.read(client) }
            }
            clients[client] = (source, Data())
            source.resume()
        }
    }

    private func read(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                clients[client]?.data.append(contentsOf: buffer[0..<count])
                if (clients[client]?.data.count ?? 0) > 1_000_000 { return finish(client) }   // far too big: drop it
            } else if count == 0 {
                return finish(client)                                                      // sender is done
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }                     // more later
                return finish(client)
            }
        }
    }

    private func finish(_ client: Int32) {
        guard let entry = clients.removeValue(forKey: client) else { return }
        entry.source.cancel()
        close(client)
        for line in entry.data.split(separator: UInt8(ascii: "\n")) {
            if let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                onMessage?(message)
            }
        }
    }
}

/// Turns messages from `notchctl say` and `notchctl run` into banners.
enum CommandAlerts {
    @MainActor static func banner(for message: [String: Any]) -> Banner? {
        switch message["type"] as? String {
        case "say":
            let text = (message["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (message["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let (symbol, tint) = icon(message["icon"] as? String)
            return Banner(symbol: symbol, tint: tint, title: title ?? (text.isEmpty ? "Notch" : text),
                          subtitle: title == nil ? nil : text, duration: 4)
        case "run":
            let command = message["command"] as? String ?? "Command"
            let status = message["status"] as? Int ?? 0
            let seconds = message["seconds"] as? Double ?? 0
            let ok = status == 0
            return Banner(symbol: "terminal.fill", tint: ok ? .green : .red,
                          title: ok ? "\(command) finished" : "\(command) failed",
                          subtitle: ok ? "took \(duration(seconds))" : "exit \(status) after \(duration(seconds))",
                          accessory: ok ? .check : .cross, duration: 4.5)
        default:
            return nil
        }
    }

    private static func icon(_ name: String?) -> (String, Banner.Tint) {
        switch name {
        case "ok", nil, "": return name == "ok" ? ("checkmark.circle.fill", .green) : ("bell.fill", .white)
        case "fail": return ("xmark.octagon.fill", .red)
        case "info": return ("bell.fill", .white)
        default:
            // Any SF Symbol name works, e.g. --icon hammer.fill
            let valid = NSImage(systemSymbolName: name!, accessibilityDescription: nil) != nil
            return (valid ? name! : "bell.fill", .white)
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
