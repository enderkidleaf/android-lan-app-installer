import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosisReport {
    let connected: Bool
    let restartAllowed: Bool
    let summary: String
}

struct ConnectionDoctor {
    var run: ([String], TimeInterval) throws -> CommandResult
    var probe: (Endpoint) -> Bool
    var emit: (String) -> Void
    init(client: ADBClient, control: CommandControl, emit: @escaping (String) -> Void) {
        run = { try client.run($0, timeout: $1, control: control, outputLimit: 256 * 1024) }
        probe = { endpoint in let result = PortProbe.inspect(endpoint.host, port: endpoint.port, timeoutMS: 1800); if result != .open { emit(result.description) }; return result == .open }
        self.emit = emit
    }
    init(run: @escaping ([String], TimeInterval) throws -> CommandResult, probe: @escaping (Endpoint) -> Bool, emit: @escaping (String) -> Void) {
        self.run = run; self.probe = probe; self.emit = emit
    }
    // This inventory includes USB/emulators and unfamiliar states, unlike the install target list.
    static func occupants(_ result: CommandResult) -> [(String, String)]? {
        guard result.success, let header = result.output.range(of: "List of devices attached") else { return nil }
        return result.output[header.upperBound...].components(separatedBy: .newlines).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return nil }
            return (words[0], words.count > 1 ? words[1] : "unknown")
        }
    }
    func command(_ args: [String], seconds: TimeInterval = 8) throws -> CommandResult {
        emit("$ adb " + args.joined(separator: " "))
        let value = try run(args, seconds)
        emit(value.output.isEmpty ? "（无输出）" : value.output)
        if value.cancelled { throw ToolError.message("操作已停止。") }
        return value
    }
    func check(_ endpoint: Endpoint) throws -> DiagnosisReport {
        emit("目标：" + endpoint.address)
        let portOpen = probe(endpoint)
        emit(portOpen ? "TCP 端口可访问。" : "TCP 端口不可访问：检查设备电源、IP/端口、网络调试和本机局域网权限。")
        let inventory = try command(["devices", "-l"])
        let occupants = Self.occupants(inventory)
        let connection = try command(["connect", endpoint.address], seconds: 12)
        let updated = try command(["devices", "-l"])
        guard let latest = Self.occupants(updated) else { return DiagnosisReport(connected: false, restartAllowed: false, summary: "无法可靠读取 ADB 状态，已禁止重启服务。请查看原始输出。") }
        if latest.contains(where: { $0.0 == endpoint.address && $0.1 == "unauthorized" }) || connection.output.localizedCaseInsensitiveContains("unauthorized") || connection.output.contains("authenticate") {
            return DiagnosisReport(connected: false, restartAllowed: false, summary: "等待设备授权：请在目标设备上选择允许调试，然后重新检查。")
        }
        let ready = latest.contains { $0.0 == endpoint.address && $0.1 == "device" }
        if ready {
            let shell = try command(["-s", endpoint.address, "shell", "echo ADB_DIAG_OK"])
            if shell.success && shell.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ADB_DIAG_OK" {
                return DiagnosisReport(connected: true, restartAllowed: false, summary: portOpen ? "连接正常，授权和设备命令通道均可用，无需重启服务。" : "ADB 命令通道正常，但应用端口探测受阻，可能与本机权限或网络策略有关。可继续使用 ADB，无需重启服务。")
            }
        }
        let other = latest.filter { $0.0 != endpoint.address }
        if !other.isEmpty { return DiagnosisReport(connected: false, restartAllowed: false, summary: "存在其他 ADB 设备（包括 USB / 模拟器），不会重启共享服务。请查看输出并处理目标设备的连接。") }
        if !portOpen { return DiagnosisReport(connected: false, restartAllowed: false, summary: "目标端口不可访问，重启 ADB 不能解决网络或设备端口问题。请确认网络调试开关与正确端口。") }
        guard occupants != nil else { return DiagnosisReport(connected: false, restartAllowed: false, summary: "最初的 ADB 状态无法确认，暂不重启共享服务。") }
        return DiagnosisReport(connected: false, restartAllowed: true, summary: "端口可访问，但 ADB 命令通道失败，可能是后台服务或设备连接异常。可点击修复连接。")
    }
    func diagnose(_ input: String, repair: Bool) throws -> DiagnosisReport {
        let endpoint = try Endpoint(input)
        let report = try check(endpoint)
        guard repair, !report.connected else { return report }
        guard report.restartAllowed else { return report }
        // Recheck immediately before stopping the shared service; never trust an earlier UI report.
        let inventory = try command(["devices", "-l"])
        guard let devices = Self.occupants(inventory), !devices.contains(where: { $0.0 != endpoint.address || $0.1 == "unauthorized" }) else {
            return DiagnosisReport(connected: false, restartAllowed: false, summary: "设备状态已变化，已取消服务重启。请重新检查。")
        }
        emit("未发现其他设备，开始重启本机 ADB 服务。不会更改设备设置或清除授权密钥。")
        let stopped = try command(["kill-server"])
        guard stopped.success else { return DiagnosisReport(connected: false, restartAllowed: false, summary: "停止服务失败，请查看输出；未继续重启。") }
        let started = try command(["start-server"])
        guard started.success else { return DiagnosisReport(connected: false, restartAllowed: false, summary: "启动 ADB 服务失败，请查看输出。") }
        let verified = try check(endpoint)
        return DiagnosisReport(connected: verified.connected, restartAllowed: false, summary: verified.connected ? verified.summary : "服务已重启，但连接仍未恢复。" + verified.summary)
    }
}

@MainActor final class TroubleshootingModel: ObservableObject {
    let client: ADBClient
    @Published var address: String
    @Published var commandText = "getprop ro.product.model"
    @Published var output = ""
    @Published var busy = false
    @Published var summary = "输入目标 IP:端口，检查连接或查看终端。"
    var control: CommandControl?
    init(client: ADBClient, address: String, initialOutput: String = "") { self.client = client; self.address = address; output = initialOutput }
    func append(_ text: String) { output += text + "\n"; if output.utf8.count > 256 * 1024 { output = String(output.suffix(120_000)) } }
    func diagnose(repair: Bool) {
        guard !busy else { return }
        let target = address, client = client, control = CommandControl()
        self.control = control; busy = true; summary = repair ? "正在检查并修复…" : "正在检查连接…"
        append("\n[\(Date().formatted())] \(summary)")
        Task {
            let result = await Task.detached { Result { try ConnectionDoctor(client: client, control: control, emit: { text in Task { @MainActor in self.append(text) } }).diagnose(target, repair: repair) } }.value
            switch result {
            case .success(let report): summary = report.summary
            case .failure(let error): summary = error.localizedDescription
            }
            append(summary); busy = false; self.control = nil
        }
    }
    func terminal(host: [String]? = nil) {
        guard !busy else { return }
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "__ADB_TERM_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let args: [String]
        do {
            if let host {
                guard [["version"], ["devices", "-l"], ["server-status"], ["mdns", "services"]].contains(host) else { throw ToolError.message("不支持的本机诊断命令。") }
                args = host
            } else {
                guard (try? Endpoint(target)) != nil || target.range(of: "^adb-[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw ToolError.message("请输入设备 IP:端口或已连接的无线设备序列号。") }
                args = ["-s", target, "shell", try TerminalCodec.wrap(commandText, marker: marker)]
            }
        } catch { summary = error.localizedDescription; return }
        let client = client, control = CommandControl(), label = host.map { "本机 adb " + $0.joined(separator: " ") } ?? "\(target) $ \(commandText)"
        self.control = control; busy = true; summary = "正在执行，可点击停止。"
        append("\n[\(Date().formatted())] \(label)")
        let prefix = output
        Task {
            let result = await Task.detached { Result { try client.run(args, timeout: 60, control: control, outputLimit: 256 * 1024, onOutput: { text in
                let visible = host == nil ? TerminalCodec.parse(text, marker: marker).0 : text
                Task { @MainActor in if self.busy && self.control === control { self.output = prefix + visible } }
            }) } }.value
            switch result {
            case .success(let value):
                let parsed = host == nil ? TerminalCodec.parse(value.output, marker: marker) : (value.output, Int(value.code))
                output = prefix + parsed.0
                summary = value.cancelled ? "已停止当前命令。" : value.outputLimited ? "输出达到 256 KB，已停止当前命令。" : value.timedOut ? "命令超过 60 秒，已停止当前命令。" : "命令结束，退出码：\(parsed.1.map(String.init) ?? "未返回")"
                append("\n[\(summary)]")
            case .failure(let error): summary = error.localizedDescription; append(summary)
            }
            busy = false; self.control = nil
        }
    }
    func stop() { control?.cancel() }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "ADB排障记录.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8); summary = "排障记录已导出。" }
        catch { summary = error.localizedDescription }
    }
}

struct TroubleshootingView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject var model: TroubleshootingModel
    @State var tab = 0
    init(client: ADBClient, address: String, initialOutput: String) { _model = StateObject(wrappedValue: TroubleshootingModel(client: client, address: address, initialOutput: initialOutput)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("连接诊断与 ADB 终端").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.disabled(model.busy) }
            TextField("目标 IP:端口，例如 192.168.1.73:5555", text: $model.address).textFieldStyle(.roundedBorder).disabled(model.busy)
            Picker("功能", selection: $tab) { Text("连接诊断与修复").tag(0); Text("ADB 终端").tag(1) }.pickerStyle(.segmented)
            if tab == 0 {
                Text("检查目标端口、设备授权与命令通道。仅在未发现其他 ADB 设备时尝试重启本机服务。").font(.caption).foregroundStyle(muted)
                HStack { Button("检查连接") { model.diagnose(repair: false) }; Button("修复连接") { model.diagnose(repair: true) }; Spacer(); Link("macOS 本地网络权限说明", destination: URL(string: "https://support.apple.com/zh-cn/guide/mac-help/mchla4f49138/mac")!) }.disabled(model.busy)
            } else {
                Text("命令在上方目标设备执行。一次运行一条，不支持交互；自定义命令可能改动设备数据。").font(.caption).foregroundStyle(muted)
                HStack { Button("设备型号") { model.commandText = "getprop ro.product.model" }; Button("存储空间") { model.commandText = "df -h /data" }; Button("最近系统日志") { model.commandText = "logcat -d -t 200" }; Button("本机设备列表") { model.terminal(host: ["devices", "-l"]) }; Button("后台服务状态") { model.terminal(host: ["server-status"]) } }.disabled(model.busy)
                HStack { Text("adb shell").font(.system(.caption, design: .monospaced)); TextField("输入设备命令", text: $model.commandText).textFieldStyle(.roundedBorder).onSubmit { model.terminal() }; Button("运行") { model.terminal() } }.disabled(model.busy)
            }
            ScrollViewReader { reader in
                ScrollView { Text(model.output.isEmpty ? "诊断结果与命令输出会显示在这里。" : model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12); Color.clear.frame(height: 1).id("end") }
                    .background(Color.black.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                    .onChange(of: model.output) { _ in reader.scrollTo("end", anchor: .bottom) }
            }
            HStack { Button("复制输出") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.output, forType: .string) }; Button("导出…") { model.export() }; Button("清空") { model.output = "" }.disabled(model.busy); Spacer(); if model.busy { ProgressView().controlSize(.small); Button("停止") { model.stop() } } }
            Text(model.summary).font(.caption).foregroundStyle(muted).textSelection(.enabled)
        }.padding(24).frame(width: 850, height: 650).tint(accent).preferredColorScheme(.light)
            .onAppear { AppState.troubleshooting = model }
            .onDisappear { model.stop(); AppState.troubleshooting = nil }
    }
}
