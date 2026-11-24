// notchctl: send things to the Notch app.
//
//   notchctl say "Deploy finished" [--title "Staging"] [--icon ok|fail|info|<SF Symbol>]
//   notchctl run -- swift build      runs the command, then shows how it went and how long it took
//   notchctl claude                  for Claude Code hooks: reads the hook's JSON from stdin
//
// Talks to the app over a private Unix socket (see AlertServer.swift). If Notch isn't
// running, `say` says so and exits 1; `run` still runs the command; `claude` stays silent
// so it never gets in Claude Code's way.
import Darwin
import Foundation

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Notch/notch.sock").path

func send(_ object: [String: Any]) -> Bool {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
    data.append(UInt8(ascii: "\n"))
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard socketPath.utf8.count < capacity else { return false }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, socketPath, capacity - 1) }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return false }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return written == data.count
}

/// The processes above this one (the hook's shell, Claude Code, the app it runs in…),
/// nearest first, so Notch can bring the right app, tab or window forward.
func ancestors() -> [Int] {
    var chain: [Int] = []
    var pid = getppid()
    while pid > 1 && chain.count < 16 {
        chain.append(Int(pid))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
        pid = pid_t(info.pbi_ppid)
    }
    return chain
}

func usage() -> Never {
    fputs("""
    usage:
      notchctl say <message> [--title <title>] [--icon ok|fail|info|<SF Symbol>]
      notchctl run [--] <command> [args…]
      notchctl claude            (Claude Code hook: reads the hook JSON from stdin)

    """, stderr)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }
let command = args.removeFirst()

switch command {
case "say":
    var title = "", icon = "", words: [String] = []
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--title" where index + 1 < args.count: title = args[index + 1]; index += 2
        case "--icon" where index + 1 < args.count: icon = args[index + 1]; index += 2
        default: words.append(args[index]); index += 1
        }
    }
    guard !words.isEmpty || !title.isEmpty else { usage() }
    if !send(["type": "say", "title": title, "message": words.joined(separator: " "), "icon": icon]) {
        fputs("notchctl: Notch isn't running\n", stderr)
        exit(1)
    }

case "run":
    if args.first == "--" { args.removeFirst() }
    guard !args.isEmpty else { usage() }
    // Ctrl-C should stop the command, not us: we need to stay to report how it ended.
    // (A handler, unlike SIG_IGN, isn't inherited by the child.)
    signal(SIGINT) { _ in }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    let started = Date()
    let id = UUID().uuidString
    _ = send(["type": "run-start", "id": id, "command": args.joined(separator: " ")])   // keeps the Mac awake
    do {
        try process.run()
    } catch {
        fputs("notchctl: couldn't run \(args[0]): \(error.localizedDescription)\n", stderr)
        exit(127)
    }
    process.waitUntilExit()
    let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    _ = send(["type": "run", "id": id, "command": args.joined(separator: " "), "status": Int(status),
              "seconds": Date().timeIntervalSince(started)])
    exit(status)

case "claude":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let hook = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
        var message: [String: Any] = ["type": "claude", "hook": HookForward.hook(hook), "ancestors": ancestors()]
        // A session the Claude app started carries the app's own ID for it ("local_…"), which
        // its claude://code/continue link opens. Only that exact shape is passed on.
        if let app = ProcessInfo.processInfo.environment["CLAUDE_CODE_HOST_SESSION_ID"],
           app.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil {
            message["appSession"] = app
        }
        _ = send(message)
    }
    exit(0)

default:
    usage()
}
