import Foundation
import Network

/// Local WebSocket server that the Chrome extension (ChromeExtension/) connects to.
/// It listens on 127.0.0.1 only, and rejects any handshake whose Origin isn't a
/// Chrome extension, so ordinary web pages can't talk to it.
@MainActor final class BrowserBridge {
    /// Below 49152 on purpose: macOS hands out 49152–65535 at random for outgoing
    /// connections, so a port in that range can be briefly taken by another app.
    static let port: UInt16 = 47821

    /// Called with what's playing in Chrome, or nil when nothing is.
    var onUpdate: ((NowPlaying?) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var lastLogged = ""
    private var retryDelay: TimeInterval = 2
    private var failing = false

    func start() {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value ?? ""
            let allowed = origin.hasPrefix("chrome-extension://")
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log("couldn't start the browser bridge: \(error)")
        }
    }

    /// If the port is busy (say, another copy of Notch is running), keep retrying
    /// with backoff instead of giving up; whichever copy is left takes over.
    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            log(failing ? "browser bridge is listening again on 127.0.0.1:\(Self.port)"
                        : "listening for the Chrome extension on 127.0.0.1:\(Self.port)")
            failing = false
            retryDelay = 2
        case .failed(let error):
            listener?.cancel()
            listener = nil
            if !failing { log("browser bridge can't use port \(Self.port) yet (\(error)); retrying until it can") }
            failing = true
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
        default:
            break
        }
    }

    /// Ask the tab that's playing to play, pause or skip.
    func send(_ action: MediaAction, tabId: Int) {
        var payload: [String: Any] = ["type": "command", "action": action.name, "tabId": tabId]
        if case let .seek(time) = action { payload["seekTime"] = time }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let context = NWConnection.ContentContext(identifier: "command",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        for connection in connections.values {
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated { self?.dropped(id) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            let opcode = (metadata as? NWProtocolWebSocket.Metadata)?.opcode
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil || opcode == .close {
                    connection.cancel()
                    return
                }
                if opcode == .text, let data { self.handle(data) }
                self.receive(on: connection)
            }
        }
    }

    private func dropped(_ id: ObjectIdentifier) {
        guard connections.removeValue(forKey: id) != nil else { return }
        // Chrome quit or the extension reloaded: whatever it was playing is gone.
        if connections.isEmpty { onUpdate?(nil) }
    }

    // MARK: Messages

    private struct Message: Decodable {
        var type: String
        var tabId: Int?
        var title: String?
        var artist: String?
        var site: String?
        var artwork: String?
        var kind: String?               // "video" or "audio" (extension 0.5 on)
        var isPlaying: Bool?
        var canSkip: Bool?
        var canSeek: Bool?
        var duration: Double?
        var position: Double?
        var rate: Double?
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        switch message.type {
        case "nowPlaying":
            guard let tabId = message.tabId else { return }
            // Only load artwork over https; pages choose this URL.
            let artwork = message.artwork.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
            let duration = message.duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            let nowPlaying = NowPlaying(title: message.title ?? "",
                                        artist: message.artist ?? "",
                                        source: message.site ?? "Browser",
                                        artworkURL: artwork,
                                        isPlaying: message.isPlaying ?? false,
                                        canSkip: message.canSkip ?? false,
                                        canSeek: (message.canSeek ?? false) && duration != nil,
                                        duration: duration,
                                        position: max(0, message.position ?? 0),
                                        positionDate: Date(),
                                        rate: message.rate ?? 1,
                                        origin: .browser(tabId: tabId),
                                        isVideo: message.kind == "video")
            // Playhead syncs arrive every few seconds; only log real changes.
            let line = "browser: \(nowPlaying.isPlaying ? "playing" : "paused") \"\(nowPlaying.title)\" on \(nowPlaying.source)"
            if line != lastLogged { log(line); lastLogged = line }
            onUpdate?(nowPlaying)
        case "cleared":
            if lastLogged != "cleared" { log("browser: nothing playing"); lastLogged = "cleared" }
            onUpdate?(nil)
        default:
            break   // heartbeat
        }
    }
}

/// Unbuffered, timestamped log line: to stdout (the terminal running `swift run`) and to
/// ~/Library/Logs/Notch.log (the app has no terminal; `bin/notch` tails this file).
func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SS"          // 24-hour
    let line = Data("\(formatter.string(from: Date())) Notch: \(message)\n".utf8)
    FileHandle.standardOutput.write(line)
    if LogFile.enabled { LogFile.append(line) }
}

enum LogFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notch.log")
    /// Only the app writes the log file (`swift run` has its terminal; tests stay out of it).
    static let enabled = Bundle.main.bundleURL.pathExtension == "app"
    private static let queue = DispatchQueue(label: "notch.log")

    static func append(_ line: Data) {
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            // Start afresh past 2 MB so it never grows without bound.
            if let size = try? handle.seekToEnd(), size > 2_000_000 {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: line)
        }
    }
}
