import Foundation

@main struct CoreTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1
        }
        func rejects(_ block: () throws -> Void, _ message: String) {
            do { try block(); check(false, message) } catch { checks += 1 }
        }
        let endpoint = try Endpoint(" 192.168.1.73 ")
        check(endpoint.address == "192.168.1.73:5555", "default port")
        let custom = try Endpoint("192.168.1.73:39000")
        check(custom.port == 39000, "custom port")
        for value in ["", "192.168.1.999", "192.168.1", "127.0.0.1", "0.0.0.0", "192.168.1.73:0", "192.168.1.73:65536", "192.168.1.73; touch /tmp/test", "192.168.1.73:5555:1"] {
            rejects({ _ = try Endpoint(value) }, "reject malformed address \(value)")
        }
        let devices = ADBParser.devices("""
        List of devices attached
        192.168.1.73:5555 device product:finch model:MiTV_MFFU0 transport_id:1
        192.168.1.74:5555 unauthorized
        192.168.1.75:5555 offline
        adb-example._adb-tls-connect._tcp device model:Wireless_TV
        emulator-5554 device model:Emulator
        usb123 device model:Phone
        * daemon started successfully *
        """)
        check(devices.count == 4, "exclude USB, emulator and daemon messages")
        check(devices[0].ready && devices[0].title == "MiTV MFFU0", "connected device parsing")
        check(devices[1].status == "等待设备授权", "unauthorized state")
        check(!devices[2].ready, "offline cannot install")
        let services = "tv _adb-tls-connect._tcp. 192.168.1.73:39000\ntv _adb-tls-pairing._tcp. 192.168.1.73:37000\ntv _adb-tls-connect._tcp. 192.168.1.73:39000"
        check(ADBParser.services(services).count == 1, "deduplicate connection broadcasts")
        check(ADBParser.services(services, pairing: true).first?.port == 37000, "pairing port separate")
        let lan = LAN(name: "en1", ip: "192.168.1.145", mask: 0xffffff00)
        check(lan.hosts.count == 253 && !lan.hosts.contains(lan.ip), "exclude own IP, network and broadcast")
        check(!lan.hosts.contains("192.168.1.0") && !lan.hosts.contains("192.168.1.255"), "valid subnet hosts")
        let small = LAN(name: "en1", ip: "192.168.1.145", mask: 0xfffffff8)
        check(Set(small.hosts) == Set(["192.168.1.146", "192.168.1.147", "192.168.1.148", "192.168.1.149", "192.168.1.150"]), "honor actual /29")
        check(LAN(name: "en1", ip: "10.3.4.5", mask: 0xffff0000).hosts.count == 253, "bound /16 scanning")
        check(LAN(name: "en1", ip: "192.168.1.145", mask: 0xffffffff).hosts.isEmpty, "handle /32")
        check(ADBParser.friendlyError("INSTALL_FAILED_UPDATE_INCOMPATIBLE").contains("签名"), "signature error explanation")
        check(ADBParser.friendlyError("INSTALL_FAILED_MISSING_SPLIT").contains("拆分"), "missing split explanation")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tv-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apk = directory.appendingPathComponent("应用 with ' quotes $(literal).apk")
        try Data([0x50,0x4b,0x03,0x04,0x00]).write(to: apk)
        let invalid = directory.appendingPathComponent("invalid.apk")
        try Data("not an APK".utf8).write(to: invalid)
        rejects({ try ADBParser.validateAPK(invalid) }, "reject disguised download")
        rejects({ try ADBParser.validateAPK(directory.appendingPathComponent("missing.apk")) }, "reject missing file")
        let args = try ADBParser.installArguments(serial: endpoint.address, files: [apk], split: false)
        check(Array(args.prefix(4)) == ["-s", endpoint.address, "install", "-r"], "explicit target and preserve-data mode")
        check(args.last == apk.path && args.count == 5, "file paths stay one literal argument")
        let split = try ADBParser.installArguments(serial: endpoint.address, files: [apk, apk], split: true)
        check(split[2] == "install-multiple" && split.count == 6, "split installation command")
        rejects({ _ = try ADBParser.installArguments(serial: "", files: [apk], split: false) }, "no default target")

        let fake = directory.appendingPathComponent("fake-adb")
        try "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\"; done\nprintf 'Success\\n'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let client = ADBClient(executable: fake)
        let result = try client.run(args)
        check(result.success && result.output.contains(apk.path), "subprocess receives literal special filename")
        check(result.output.contains("Success"), "capture successful installation output")
        try "#!/bin/sh\nprintf 'Failure [INSTALL_FAILED_NO_MATCHING_ABIS]\\n'\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        let failure = try client.run(args)
        check(!failure.success && ADBParser.friendlyError(failure.output).contains("架构"), "surface real failure exit code")
        try "#!/bin/sh\nexec /bin/sleep 20\n".write(to: fake, atomically: true, encoding: .utf8)
        let started = Date()
        let timeout = try client.run([], timeout: 0.15)
        check(timeout.timedOut && !timeout.success && Date().timeIntervalSince(started) < 4, "bounded subprocess timeout")
        check(timeout.output.contains("timed out"), "timeout diagnostic")

        check(DeviceCommands.packages("package:com.example.b\npackage:com.example.a\npackage:com.example.a\npackage:com.bad;rm -rf /\nwarning")==["com.example.a","com.example.b"], "package inventory rejects injection and deduplicates")
        for bad in ["com.x;reboot", "com.x$(id)", "com.x\nreboot", "../foo", "com.x'"] { rejects({ _ = try DeviceCommands.package(bad) }, "reject package injection") }
        check(DeviceCommands.component("priority=0\ncom.example/.Main$Nested\n") == "com.example/.Main$Nested", "resolve valid component")
        check(DeviceCommands.component("com.example/.Main;reboot") == nil, "reject component injection")
        let checked = try DeviceCommands.checked("Success\n\n__TOOLS_EXIT:0\n")
        check(checked == "Success", "remote exit marker")
        for bad in ["Success", "Failure [DELETE_FAILED_INTERNAL_ERROR]\n__TOOLS_EXIT:0\n", "Error: denied\n__TOOLS_EXIT:0\n", "denied\n__TOOLS_EXIT:1\n"] { rejects({ _ = try DeviceCommands.checked(bad) }, "reject remote failure") }
        rejects({ _ = try DeviceCommands.key("KEYCODE_HOME;reboot") }, "reject arbitrary input")
        check(!DeviceCommands.validPNG(Data("error".utf8)), "reject invalid screenshot")
        try "#!/bin/sh\n[ \\\"$1\\\" = \\\"-s\\\" ] && [ \\\"$2\\\" = \\\"192.168.1.73:5555\\\" ] || exit 9\nprintf 'package:com.example.app\\n\\n__TOOLS_EXIT:0\\n'\n".replacingOccurrences(of: "\\\"", with: "\"").write(to: fake, atomically: true, encoding: .utf8)
        let inventory = try client.toolShell("192.168.1.73:5555", "pm list packages -3 --user current")
        check(DeviceCommands.packages(inventory)==["com.example.app"], "tool command pins exact target")
        print("PASS: \(checks) checks")
    }
}
