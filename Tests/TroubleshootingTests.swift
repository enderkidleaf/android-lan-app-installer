import Foundation

@main struct TroubleshootingTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }; checks += 1 }
        let target = "192.0.2.1:5555"
        check(PortProbe.status(ECONNREFUSED) == .refused, "refused port classified")
        check(PortProbe.status(EHOSTUNREACH) == .unreachable, "network failure classified")
        check(PortProbe.status(ETIMEDOUT) == .timeout, "timeout classified")
        check(PortProbe.status(EPERM) == .permission, "local permission classified")
        func scenario(_ mode: String, repair: Bool = true) throws -> (DiagnosisReport, [[String]]) {
            var healed = mode.hasPrefix("healthy"), inventoryCalls = 0
            var calls: [[String]] = []
            let doctor = ConnectionDoctor(run: { args, _ in
                calls.append(args)
                if args == ["devices", "-l"] {
                    inventoryCalls += 1
                    if mode == "badInventory" { return CommandResult(code: 0, output: "unknown format", timedOut: false) }
                    var row = healed ? "\(target) device\n" : ""
                    if mode == "unauthorized" { row = "\(target) unauthorized\n" }
                    if mode == "usb" || (mode == "race" && inventoryCalls >= 3) { row += "USB_DEVICE device\n" }
                    if mode == "emulator" { row += "emulator-5554 offline\n" }
                    return CommandResult(code: 0, output: "List of devices attached\n" + row, timedOut: false)
                }
                if args == ["start-server"] {
                    if mode == "startFailure" { return CommandResult(code: 1, output: "cannot start", timedOut: false) }
                    healed = true
                }
                if args == ["-s", target, "shell", "echo ADB_DIAG_OK"] { return CommandResult(code: 0, output: "ADB_DIAG_OK\n", timedOut: false) }
                return CommandResult(code: healed ? 0 : 1, output: healed ? "connected" : "No route to host", timedOut: false)
            }, probe: { _ in mode != "closedPort" && mode != "healthyProbeBlocked" }, emit: { _ in })
            // A successful kill is required before a restart.
            let actual = ConnectionDoctor(run: { args, timeout in
                if args == ["kill-server"] { calls.append(args); return CommandResult(code: 0, output: "", timedOut: false) }
                return try doctor.run(args, timeout)
            }, probe: doctor.probe, emit: { _ in })
            let report = try actual.diagnose(target, repair: repair)
            return (report, calls)
        }
        let healthy = try scenario("healthy"); check(healthy.0.connected && !healthy.1.contains(["kill-server"]), "healthy connection never restarts")
        let blocked = try scenario("healthyProbeBlocked"); check(blocked.0.connected && blocked.0.summary.contains("探测受阻") && !blocked.1.contains(["kill-server"]), "working ADB takes precedence over blocked direct probe")
        let stale = try scenario("stale"); check(stale.0.connected && stale.1.filter { $0 == ["kill-server"] }.count == 1, "repair stale service then verify shell")
        let readOnly = try scenario("stale", repair: false); check(readOnly.0.restartAllowed && !readOnly.1.contains(["kill-server"]), "check only does not restart")
        for mode in ["unauthorized", "usb", "emulator", "closedPort", "badInventory", "race"] {
            let result = try scenario(mode); check(!result.0.connected && !result.1.contains(["kill-server"]), "protect \(mode)")
        }
        let failed = try scenario("startFailure"); check(!failed.0.connected && failed.0.summary.contains("启动"), "start failure surfaced")
        let control = CommandControl(); control.cancel()
        let cancelled = ConnectionDoctor(run: { _, _ in CommandResult(code: -1, output: "", timedOut: false, cancelled: true) }, probe: { _ in true }, emit: { _ in })
        do { _ = try cancelled.diagnose(target, repair: true); check(false, "cancel aborts repair") } catch { checks += 1 }
        for value in ["", "\0", String(repeating: "x", count: 8193)] { do { _ = try TerminalCodec.validate(value); check(false, "invalid terminal command") } catch { checks += 1 } }
        let parsed = TerminalCodec.parse("错误输出\nMARK:7\n", marker: "MARK"); check(parsed.0 == "错误输出" && parsed.1 == 7, "nonzero remote status parsed")
        check(TerminalCodec.parse("MARK:0\npartial", marker: "MARK").1 == nil, "missing marker never implies success")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("troubleshooting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-adb")
        try "#!/bin/sh\n[ \"$1\" = '-s' ] && [ \"$2\" = '\(target)' ] && [ \"$3\" = 'shell' ] || exit 9\nexec /bin/sh -c \"$4\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = ADBClient(executable: script)
        let wrapped = try TerminalCodec.wrap("printf 'first\\n'; printf 'problem\\n' >&2; exit 7", marker: "MARK")
        let result = try client.run(["-s",target,"shell",wrapped], timeout: 3, outputLimit: 256 * 1024)
        let remote = TerminalCodec.parse(result.output, marker: "MARK")
        check(remote.0.contains("first") && remote.0.contains("problem") && remote.1 == 7, "actual process routes stderr and preserves exit in subshell")
        let stop = CommandControl()
        try "#!/bin/sh\nprintf 'partial\\n'\nexec /bin/sleep 20\n".write(to: script, atomically: true, encoding: .utf8)
        var stopScheduled = false
        let begin = Date(); let stopped = try client.run([], timeout: 5, control: stop, outputLimit: 256 * 1024, onOutput: { text in if text.contains("partial") && !stopScheduled { stopScheduled = true; DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { stop.cancel() } } })
        check(stopped.cancelled && stopped.output.contains("partial") && Date().timeIntervalSince(begin) < 3, "stop ends only this command and retains partial output")
        let before = try client.run([], control: control); check(before.cancelled && before.output.isEmpty, "pre-cancel does not launch")
        try "#!/bin/sh\nexec /usr/bin/yes output\n".write(to: script, atomically: true, encoding: .utf8)
        let limited = try client.run([], timeout: 3, outputLimit: 4096); check(limited.outputLimited && limited.output.utf8.count <= 4096, "output limit bounds returned transcript")
        try "#!/bin/sh\nprintf 'live\\n'\nexec /bin/sleep 0.2\n".write(to: script, atomically: true, encoding: .utf8)
        var snapshots: [String] = []
        _ = try client.run([], timeout: 3, outputLimit: 4096, onOutput: { snapshots.append($0) })
        check(snapshots.contains { $0.contains("live") }, "live output emitted before completion")
        print("PASS: \(checks) troubleshooting checks")
    }
}
