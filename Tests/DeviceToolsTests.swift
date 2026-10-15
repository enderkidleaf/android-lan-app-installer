import Foundation
import AppKit

@main struct DeviceToolsTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("fixture.png"))
        let script = root.appendingPathComponent("fake-adb"), calls = root.appendingPathComponent("calls"), fail = root.appendingPathComponent("fail")
        try """
        #!/bin/sh
        [ "$1" = '-s' ] && [ "$2" = '192.0.2.1:5555' ] || exit 9
        printf '%s\\n' "$4" >> '\(calls.path)'
        if [ "$3" = 'pull' ]; then cp '\(root.path)/fixture.png' "$5"; exit 0; fi
        if [ -f '\(fail.path)' ]; then printf 'Error: denied\\n\\n__TOOLS_EXIT:1\\n'; exit 0; fi
        case "$4" in
          'pm list packages -3'*) printf 'package:com.example.app\\npackage:com.example.app\\n';;
          'pm list packages --user'*) printf 'package:com.example.app\\npackage:com.android.settings\\n';;
          'cmd package resolve-activity'*'LEANBACK_LAUNCHER'*) printf 'No activity found\\n';;
          'cmd package resolve-activity'*) printf 'com.example.app/.Main$Nested\\n';;
          'pm uninstall'*) printf 'Success\\n';;
          'pm clear'*) printf 'Success\\n';;
        esac
        printf '\\n__TOOLS_EXIT:0\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let model = DeviceToolsModel(target: Device(serial: "192.0.2.1:5555", state: "device", model: "Test_Device"), client: ADBClient(executable: script))
        var checks = 0
        func check(_ value: Bool, _ text: String) { guard value else { fputs("FAIL: \(text)\n", stderr); exit(1) }; checks += 1 }
        func finish() async throws {
            let deadline = Date().addingTimeInterval(8)
            while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            check(!model.busy, "operation terminates")
        }
        model.refresh(); try await finish()
        check(model.apps.count == 1 && !model.apps[0].system, "refresh reads and deduplicates user apps")
        model.includeSystem = true; model.refresh(); try await finish()
        check(model.apps.count == 2 && model.apps.first { $0.package == "com.android.settings" }?.system == true, "system inventory classification")
        model.filter = "example"; check(model.visible.count == 1, "search does not mutate full inventory")
        model.selected = "com.example.app"; model.launch(); try await finish()
        let log = try String(contentsOf: calls, encoding: .utf8)
        check(log.contains("LEANBACK_LAUNCHER") && log.contains("category.LAUNCHER") && log.contains("-n 'com.example.app/.Main$Nested'"), "fallback launcher and quoted inner class")
        model.capture(); try await finish()
        check(model.screenshot == png && NSImage(data: png) != nil, "screenshot preserves binary and decodes")
        check(try String(contentsOf: calls, encoding: .utf8).contains("rm -f /data/local/tmp/android-lan-screen-"), "temporary screenshot cleaned")
        try Data().write(to: fail); model.action("卸载"); try await finish()
        check(model.failed && model.apps.count == 2, "failed uninstall preserves inventory")
        model.capture(); try await finish(); check(model.failed && model.screenshot == png, "failed capture retains last good image")
        try FileManager.default.removeItem(at: fail)
        model.action("卸载"); try await finish(); check(model.apps.count == 1 && model.selected == nil, "successful uninstall removes selected app")
        model.selected = "com.android.settings"; model.action("卸载"); check(!model.busy && model.apps.count == 1, "system uninstall guarded without sending command")
        model.action("清除数据"); check(!model.busy && model.apps.count == 1, "system data deletion guarded")
        model.key("KEYCODE_HOME;reboot"); try await finish(); check(model.failed, "unknown key cannot reach device")
        print("PASS: \(checks) device tools model checks (simulated ADB, no real device mutations)")
    }
}
