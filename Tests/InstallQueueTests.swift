import Foundation

@main struct InstallQueueTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("install-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-adb")
        let calls = root.appendingPathComponent("install-calls")
        let source = """
        #!/bin/sh
        if [ "$3" = "get-state" ]; then printf 'device\\n'; exit 0; fi
        printf 'CALL\\n' >> '\(calls.path)'
        printf '%s\\n' "$@" >> '\(calls.path)'
        for arg in "$@"; do
            case "$arg" in *fail.apk) printf 'Failure [INSTALL_FAILED_TEST]\\n'; exit 1;; *slow.apk) sleep 0.2;; esac
        done
        printf 'Success\\n'
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = ADBClient(executable: script)
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }; checks += 1
        }
        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try Data([0x50, 0x4b, 3, 4, 0]).write(to: url); return url
        }
        func model() -> InstallerModel {
            let m = InstallerModel(client: client)
            m.devices = [Device(serial: "192.0.2.1:5555", state: "device", model: "Test_Device")]
            m.selectedSerial = m.devices[0].serial
            return m
        }
        func finish(_ m: InstallerModel) async throws {
            let deadline = Date().addingTimeInterval(8)
            while m.installing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            check(!m.installing, "queue terminates")
        }
        func count(_ name: String) throws -> Int {
            try String(contentsOf: calls, encoding: .utf8).components(separatedBy: .newlines).filter { $0 == root.appendingPathComponent(name).path }.count
        }
        let m = model(), a = try file("first-a.apk"), b = try file("first-b.apk"), c = try file("second.apk")
        m.addFiles([a,b]); m.install(); try await finish(m)
        check(m.files.isEmpty && m.installedFiles.count == 2 && !m.canInstall, "first batch leaves pending queue")
        check(m.installedFiles.allSatisfy { $0.target.contains("192.0.2.1:5555") }, "history retains target")
        m.addFiles([c]); check(m.files.count == 1 && m.installedFiles.count == 2, "new selection stays separate")
        m.install(); try await finish(m)
        check(try count("first-a.apk") == 1 && count("first-b.apk") == 1 && count("second.apk") == 1, "second batch never reinstalls first batch")
        check(m.installedFiles.count == 3 && m.files.isEmpty, "second success appends history")
        m.installedFiles.removeAll(); check(m.files.isEmpty && !m.canInstall, "clearing history never queues old APKs")
        m.addFiles([a]); m.install(); try await finish(m)
        check(try count("first-a.apk") == 2, "explicit reselection can install again")
        let good = try file("good.apk"), fail = try file("fail.apk"), next = try file("new.apk")
        m.addFiles([good,fail]); m.install(); try await finish(m)
        check(m.files.count == 1 && m.files[0].state == "安装失败" && m.files[0].url == fail, "failed item alone remains retryable")
        m.addFiles([next]); m.install(); try await finish(m)
        check(try count("good.apk") == 1 && count("new.apk") == 1 && count("fail.apk") == 2, "mixed retry does not reinstall successful APK")
        check(!m.installedFiles.contains { $0.name == "fail.apk" }, "failure never enters history")
        let split = model(), base = try file("base.apk"), part = try file("split.apk")
        split.splitMode = true; split.addFiles([base,part]); split.install(); try await finish(split)
        check(split.files.isEmpty && split.installedFiles.count == 2, "split commit archives all parts together")
        split.addFiles([base,fail]); split.install(); try await finish(split)
        check(split.files.count == 2 && split.installedFiles.count == 2, "failed split keeps all parts and preserves prior history")
        let stopped = model(), slow = try file("slow.apk"), later = try file("later.apk")
        stopped.addFiles([slow,later]); stopped.install()
        while !stopped.files.contains(where: { $0.state == "安装中" }) { try await Task.sleep(nanoseconds: 1_000_000) }
        stopped.cancelRemaining = true; try await finish(stopped)
        check(stopped.installedFiles.count == 1 && stopped.installedFiles[0].name == "slow.apk", "current success archives before stop")
        check(stopped.files.count == 1 && stopped.files[0].url == later && stopped.files[0].state == "已跳过", "unstarted item remains after stop")
        check(try count("later.apk") == 0, "stop never invokes later item")
        print("PASS: \(checks) installation queue regression checks (real model, simulated ADB)")
    }
}
