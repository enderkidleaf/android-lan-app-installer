import Foundation
import Darwin

enum ToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Endpoint: Equatable {
    let host: String
    let port: Int
    var address: String { "\(host):\(port)" }

    init(_ input: String, defaultPort: Int = 5555) throws {
        let pieces = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { throw ToolError.message("请输入 IPv4 地址，例如 192.168.1.73:5555。") }
        let parts = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }) else {
            throw ToolError.message("IP 地址格式不正确，例如 192.168.1.73。")
        }
        let host = parts.map { String(Int($0)!) }.joined(separator: ".")
        guard let port = pieces.count == 2 ? Int(pieces[1]) : defaultPort, (1...65535).contains(port) else {
            throw ToolError.message("端口应在 1 到 65535 之间。")
        }
        guard !host.hasPrefix("127."), host != "0.0.0.0", !host.hasPrefix("255.") else {
            throw ToolError.message("请输入设备的局域网 IP 地址。")
        }
        self.host = host
        self.port = port
    }
}

struct Device: Identifiable, Equatable {
    let serial: String
    var state: String
    var model: String
    var manufacturer = ""
    var android = ""
    var architecture = ""
    var id: String { serial }
    var ready: Bool { state == "device" }
    var status: String {
        switch state {
        case "device": return "已连接"
        case "unauthorized": return "等待设备授权"
        case "offline": return "设备离线"
        default: return state
        }
    }
    var title: String { model.isEmpty ? "Android 设备" : model.replacingOccurrences(of: "_", with: " ") }
}

enum ADBParser {
    static func devices(_ output: String) -> [Device] {
        output.components(separatedBy: .newlines).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 2, ["device", "offline", "unauthorized"].contains(words[1]) else { return nil }
            // This app only installs through network ADB. Leave USB devices/emulators out of selection.
            guard words[0].contains(":") || words[0].hasPrefix("adb-") || words[0].contains("._adb-tls-connect.") else { return nil }
            let model = words.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
            return Device(serial: words[0], state: words[1], model: model)
        }
    }

    static func services(_ output: String, pairing: Bool = false) -> [Endpoint] {
        let service = pairing ? "_adb-tls-pairing._tcp" : "_adb-tls-connect._tcp"
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3, line.contains(service), let endpoint = try? Endpoint(String(words.last!)), seen.insert(endpoint.address).inserted else { return nil }
            return endpoint
        }
    }

    static func installArguments(serial: String, files: [URL], split: Bool) throws -> [String] {
        guard !serial.isEmpty, !files.isEmpty else { throw ToolError.message("请先选择设备和 APK 文件。") }
        try files.forEach(validateAPK)
        return ["-s", serial, split ? "install-multiple" : "install", "-r"] + files.map(\.path)
    }

    static func validateAPK(_ file: URL) throws {
        guard file.pathExtension.lowercased() == "apk" else { throw ToolError.message("请选择 .apk 文件；XAPK、APKM 和 AAB 不能直接安装。") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isReadableFile(atPath: file.path) else { throw ToolError.message("无法读取文件：\(file.lastPathComponent)") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw ToolError.message("\(file.lastPathComponent) 不是有效的 APK / ZIP 文件。")
        }
    }

    static func friendlyError(_ raw: String) -> String {
        if raw.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") { return "签名与已安装版本不同。请使用同一来源的 APK；卸载旧版本会删除应用数据。" }
        if raw.contains("INSTALL_FAILED_VERSION_DOWNGRADE") { return "APK 版本低于设备上的已安装版本，请选择更新版本。" }
        if raw.contains("INSTALL_FAILED_NO_MATCHING_ABIS") { return "APK 的处理器架构不兼容，请选择与设备处理器架构匹配的版本。" }
        if raw.contains("INSTALL_FAILED_OLDER_SDK") { return "APK 要求更高的 Android 版本，请选择兼容版本。" }
        if raw.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") { return "设备存储空间不足，请先清理空间。" }
        if raw.contains("INSTALL_FAILED_USER_RESTRICTED") { return "设备限制了安装。请检查未知来源安装设置，并确认设备上的提示。" }
        if raw.contains("INSTALL_FAILED_MISSING_SPLIT") { return "这是拆分 APK。请选齐同一应用的 base 和 split 文件，并开启拆分 APK 模式。" }
        if raw.localizedCaseInsensitiveContains("unauthorized") || raw.contains("authenticate") { return "请在设备弹出的调试授权窗口选择「允许」，然后点击刷新状态。" }
        if raw.localizedCaseInsensitiveContains("refused") { return "设备未开放此 ADB 端口。请检查 ADB 调试开关，或使用无线调试页面显示的连接端口。" }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.contains("Host is down") || raw.contains("No route") { return "无法访问设备。请确认设备已开机、IP 正确，电脑和设备在同一局域网，且没有访客网络或客户端隔离。" }
        if raw.contains("offline") || raw.contains("not found") || raw.contains("no devices") { return "设备离线，请重新连接设备。" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CommandResult {
    let code: Int32
    let output: String
    let timedOut: Bool
    var cancelled = false
    var outputLimited = false
    var success: Bool { code == 0 && !timedOut && !cancelled && !outputLimited }
}

final class CommandControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func attach(_ process: Process) { lock.lock(); self.process = process; let cancel = stopped; lock.unlock(); if cancel && process.isRunning { process.terminate() } }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func cancel() { lock.lock(); stopped = true; let running = process; lock.unlock(); if let running, running.isRunning { running.terminate() } }
}

enum TerminalCodec {
    static func validate(_ command: String) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.utf8.count <= 8192, !command.contains("\0") else { throw ToolError.message("请输入一条命令，最多 8192 字节，不能包含空字符。") }
        return command
    }
    static func wrap(_ command: String, marker: String) throws -> String {
        "(\n" + (try validate(command)) + "\n); result=$?; printf '\\n" + marker + ":%s\\n' \"$result\""
    }
    static func parse(_ output: String, marker: String) -> (String, Int?) {
        guard let range = output.range(of: "\n" + marker + ":", options: .backwards),
              let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) else { return (output, nil) }
        return (String(output[..<range.lowerBound]), code)
    }
}

enum DeviceCommands {
    static func package(_ value: String) throws -> String {
        guard value.range(of: "\\A[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+\\z", options: .regularExpression) != nil else { throw ToolError.message("设备返回了无效的应用包名。") }
        return value
    }
    static func packages(_ output: String) -> [String] {
        Array(Set(output.components(separatedBy: .newlines).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("package:") else { return nil }
            return try? package(String(text.dropFirst(8)))
        })).sorted()
    }
    static func component(_ output: String) -> String? {
        output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first {
            $0.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+$", options: .regularExpression) != nil
        }
    }
    static let keys: [(String, String)] = [("上", "KEYCODE_DPAD_UP"), ("左", "KEYCODE_DPAD_LEFT"), ("确认", "KEYCODE_DPAD_CENTER"), ("右", "KEYCODE_DPAD_RIGHT"), ("下", "KEYCODE_DPAD_DOWN"), ("返回", "KEYCODE_BACK"), ("主页", "KEYCODE_HOME"), ("音量 −", "KEYCODE_VOLUME_DOWN"), ("音量 +", "KEYCODE_VOLUME_UP")]
    static func key(_ code: String) throws -> String {
        guard keys.contains(where: { $0.1 == code }) else { throw ToolError.message("不支持的遥控按键。") }
        return "input keyevent " + code
    }
    // A marker preserves the device command's exit status even on legacy shell transports.
    static func wrapped(_ command: String) -> String { command + "; result=$?; printf '\\n__TOOLS_EXIT:%s\\n' \"$result\"" }
    static func checked(_ output: String) throws -> String {
        guard let range = output.range(of: "\n__TOOLS_EXIT:", options: .backwards), output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { throw ToolError.message(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "设备没有确认操作成功。" : output) }
        let text = String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("Error:") || $0.hasPrefix("Exception") || $0.hasPrefix("Failure") }) { throw ToolError.message(text) }
        return text
    }
    static func validPNG(_ data: Data) -> Bool { data.count > 24 && data.starts(with: [137,80,78,71,13,10,26,10]) }
}

/// Run without a shell: IP, pairing code and filenames are always separate arguments.
struct ADBClient {
    let executable: URL

    func toolShell(_ serial: String, _ command: String) throws -> String {
        let result = try run(["-s", serial, "shell", DeviceCommands.wrapped(command)], timeout: 30)
        guard result.success else { throw ToolError.message(ADBParser.friendlyError(result.output)) }
        return try DeviceCommands.checked(result.output)
    }
    func screenshot(_ serial: String) throws -> Data {
        let remote = "/data/local/tmp/android-lan-screen-\(UUID().uuidString).png"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { _ = try? toolShell(serial, "rm -f " + remote); try? FileManager.default.removeItem(at: local) }
        _ = try toolShell(serial, "screencap -p " + remote)
        let result = try run(["-s", serial, "pull", remote, local.path], timeout: 30)
        guard result.success else { throw ToolError.message(ADBParser.friendlyError(result.output)) }
        let size = (try local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 32 * 1024 * 1024 else { throw ToolError.message("截图超过 32 MB。") }
        let data = try Data(contentsOf: local)
        guard DeviceCommands.validPNG(data) else { throw ToolError.message("设备没有返回有效截图，可能不支持截屏。") }
        return data
    }

    func run(_ arguments: [String], timeout: TimeInterval = 15, input: String? = nil,
             control: CommandControl? = nil, outputLimit: Int? = nil, onOutput: ((String) -> Void)? = nil) throws -> CommandResult {
        if control?.cancelled == true { return CommandResult(code: -1, output: "", timedOut: false, cancelled: true) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A disk-backed output handle cannot deadlock on a full stdout pipe during an install.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("tv-adb-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = stdin
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        control?.attach(process)
        defer { control?.detach() }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8)) }
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, cancelled = false, limited = false
        var previousSize: UInt64 = 0
        while true {
            let ended = finished.wait(timeout: .now() + 0.1) == .success
            let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            if size != previousSize, let onOutput {
                let reader = try FileHandle(forReadingFrom: outputURL)
                let snapshot = try outputLimit.map { try reader.read(upToCount: $0) ?? Data() } ?? (try reader.readToEnd() ?? Data())
                try? reader.close()
                onOutput(String(decoding: snapshot, as: UTF8.self))
                previousSize = size
            }
            limited = outputLimit.map { size > UInt64($0) } ?? false
            cancelled = control?.cancelled == true
            timedOut = !ended && Date() >= deadline
            if ended || limited || cancelled || timedOut { break }
        }
        if process.isRunning && (timedOut || cancelled || limited) {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try outputLimit.map { try reader.read(upToCount: $0) ?? Data() } ?? (try reader.readToEnd() ?? Data())
        let text = String(decoding: data, as: UTF8.self)
        return CommandResult(code: process.isRunning ? -1 : process.terminationStatus,
                             output: text + (timedOut ? "\n连接或操作超时 (timed out)。" : ""), timedOut: timedOut, cancelled: cancelled, outputLimited: limited)
    }

    func enrichedDevices() throws -> [Device] {
        let result = try run(["devices", "-l"])
        guard result.success else { throw ToolError.message(ADBParser.friendlyError(result.output)) }
        return ADBParser.devices(result.output).map { device in
            guard device.ready else { return device }
            var detail = device
            // Fixed commands; no interpolated user content is executed on the television.
            if let properties = try? run(["-s", device.serial, "shell", "getprop ro.product.model; getprop ro.product.manufacturer; getprop ro.build.version.release; getprop ro.product.cpu.abilist"], timeout: 6), properties.success {
                let values = properties.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if values.count >= 4 {
                    detail.model = values[0]; detail.manufacturer = values[1]
                    detail.android = values[2]; detail.architecture = values[3]
                }
            }
            return detail
        }
    }
}

struct LAN: Identifiable, Equatable {
    let name: String
    let ip: String
    let mask: UInt32
    var id: String { name + ip }
    var prefix: Int { mask.nonzeroBitCount }
    var description: String { "\(name) · \(ip)/\(prefix)" }
    var scanDescription: String { prefix < 24 ? "网络较大，仅扫描本机所在的 /24；其他地址可手动连接" : "仅扫描此局域网的 ADB 端口 5555" }
    var hosts: [String] {
        guard let own = LAN.number(ip) else { return [] }
        let effectiveMask: UInt32 = mask < 0xffffff00 ? 0xffffff00 : mask
        let base = own & effectiveMask
        let end = base | ~effectiveMask
        guard end > base + 1 else { return [] }
        return ((base + 1)..<end).filter { $0 != own }.map(LAN.string)
    }
    static func number(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { ($0 << 8) | $1 }
    }
    static func string(_ ip: UInt32) -> String { [24,16,8,0].map { String((ip >> $0) & 255) }.joined(separator: ".") }

    static func current() -> [LAN] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var current = pointer
        var networks: [LAN] = []
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let entry = item.pointee
            guard (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET, let netmask = entry.ifa_netmask else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("ipsec"), !name.hasPrefix("bridge"), !name.hasPrefix("awdl") else { continue }
            let addr = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee
            let ip = UInt32(bigEndian: addr.sin_addr.s_addr)
            guard ip >> 24 != 169, ip >> 24 != 127, mask.sin_addr.s_addr != 0 else { continue }
            networks.append(LAN(name: name, ip: string(ip), mask: UInt32(bigEndian: mask.sin_addr.s_addr)))
        }
        return networks.sorted { $0.name < $1.name }
    }
}

enum PortProbe {
    enum Status: Equatable {
        case open, refused, timeout, unreachable, permission, other(Int32)
        var description: String {
            switch self {
            case .open: return "TCP 端口可访问。"
            case .refused: return "端口拒绝连接：请检查目标设备的网络 ADB 开关和端口。"
            case .timeout: return "连接端口超时：请检查设备是否开机、IP 是否正确，以及网络隔离或防火墙。"
            case .unreachable: return "端口探测无法到达目标：请检查局域网与 IP；macOS 本地网络权限也可能阻止此访问。"
            case .permission: return "本机拒绝访问局域网：请检查 macOS 隐私与安全性中的本地网络权限。"
            case .other(let code): return "端口检查失败：系统错误 \(code)。"
            }
        }
    }
    static func status(_ error: Int32) -> Status {
        switch error { case ECONNREFUSED: return .refused; case ETIMEDOUT: return .timeout; case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return .unreachable; case EPERM, EACCES: return .permission; default: return .other(error) }
    }
    static func open(_ host: String, port: Int = 5555, timeoutMS: Int32 = 650) -> Bool {
        inspect(host, port: port, timeoutMS: timeoutMS) == .open
    }
    static func inspect(_ host: String, port: Int = 5555, timeoutMS: Int32 = 650) -> Status {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return status(errno) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return status(errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return .other(EINVAL) }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return .open }
        guard errno == EINPROGRESS else { return status(errno) }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let polled = poll(&pollFD, 1, timeoutMS)
        guard polled > 0 else { return polled == 0 ? .timeout : status(errno) }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return status(errno) }
        return error == 0 ? .open : status(error)
    }

    static func scan(_ lan: LAN, progress: @escaping (Int, Int) -> Void) -> [String] {
        let hosts = lan.hosts
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 24
        let lock = NSLock()
        var found: [String] = []
        var count = 0
        for host in hosts {
            queue.addOperation {
                let reachable = open(host)
                lock.lock()
                if reachable { found.append(host) }
                count += 1
                progress(count, hosts.count)
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return found.sorted()
    }
}
