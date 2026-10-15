import SwiftUI
import AppKit
import UniformTypeIdentifiers

let accent = Color(red: 0.93, green: 0.34, blue: 0.13)
let ink = Color(red: 0.14, green: 0.18, blue: 0.20)
let muted = Color(red: 0.43, green: 0.47, blue: 0.49)
let canvas = Color(red: 0.97, green: 0.97, blue: 0.95)

struct APKItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var state = "待安装"
    var detail = ""
}

struct InstalledAPKItem: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
    let target: String
    let date: Date?
    init(name: String, size: Int64, target: String, date: Date? = Date()) {
        self.name = name; self.size = size; self.target = target; self.date = date
    }
}

struct InstalledHistorySnapshot: Decodable {
    struct Entry: Decodable { let name: String; let size: Int64; let target: String }
    let entries: [Entry]
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
final class InstallerModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedSerial: String?
    @Published var networks = LAN.current()
    @Published var networkID = ""
    @Published var address = ""
    @Published var files: [APKItem] = []
    @Published var installedFiles: [InstalledAPKItem] = []
    @Published var splitMode = false
    @Published var busy = false
    @Published var installing = false
    @Published var cancelRemaining = false
    @Published var phase = "准备就绪"
    @Published var progress: Double = 0
    @Published var banner = "开启目标设备的网络 ADB 或无线调试后，点击「发现设备」或输入 IP 地址。"
    @Published var bannerError = false
    @Published var logs: [LogEntry] = []
    @Published var showPairing = false
    @Published var pairAddress = ""
    @Published var pairCode = ""
    @Published var connectionAddress = ""
    @Published var showLogs = false
    @Published var hovered = false

    let client: ADBClient
    var selected: Device? { devices.first { $0.serial == selectedSerial } }
    var network: LAN? { networks.first { $0.id == networkID } }
    var canInstall: Bool { !busy && selected?.ready == true && !files.isEmpty }

    init(client: ADBClient? = nil) {
        let path = Bundle.main.url(forResource: "adb", withExtension: nil)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/adb")
        self.client = client ?? ADBClient(executable: path)
        networkID = networks.first?.id ?? ""
        // Preserve an observed old-version session during an in-place update.
        // This imports display records only and never adds an APK to the install queue.
        if client == nil, let flag = CommandLine.arguments.firstIndex(of: "--restore-installed-history-json"),
           CommandLine.arguments.indices.contains(flag + 1) {
            do {
                guard let data = Data(base64Encoded: CommandLine.arguments[flag + 1]) else { throw ToolError.message("无效的旧版记录数据") }
                let snapshot = try JSONDecoder().decode(InstalledHistorySnapshot.self, from: data)
                installedFiles = snapshot.entries.map { InstalledAPKItem(name: $0.name, size: $0.size, target: $0.target, date: nil) }
            } catch { log("旧版成功记录恢复失败：\(error.localizedDescription)") }
        }
    }

    func log(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { logs.append(LogEntry(text: value)) }
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func notice(_ message: String, error: Bool = false) {
        banner = message; bannerError = error; log(message)
    }

    func updateDevices(_ value: [Device]) {
        devices = value
        if !value.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = value.first(where: \.ready)?.serial ?? value.first?.serial
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true; phase = "检查设备状态"; progress = 0
        networks = LAN.current()
        if !networks.contains(where: { $0.id == networkID }) { networkID = networks.first?.id ?? "" }
        let client = self.client
        Task {
            let result = await Task.detached { Result { try client.enrichedDevices() } }.value
            switch result {
            case .success(let value):
                updateDevices(value)
                if let ready = selected, ready.ready { notice("已连接 \(ready.title)，可以选择 APK 安装。") }
                else if value.contains(where: { $0.state == "unauthorized" }) { notice("请在设备上允许此电脑进行 ADB 调试，然后刷新状态。", error: true) }
                else { notice("暂无已连接的设备。点击「发现设备」，或输入设备 IP 连接。") }
            case .failure(let error): notice(error.localizedDescription, error: true)
            }
            busy = false; phase = "准备就绪"
        }
    }

    func connect(_ input: String? = nil) {
        guard !busy else { return }
        let endpoint: Endpoint
        do { endpoint = try Endpoint(input ?? address) }
        catch { notice(error.localizedDescription, error: true); return }
        busy = true; phase = "连接 \(endpoint.address)"; progress = 0
        let client = self.client
        log("连接 \(endpoint.address)")
        Task {
            let result = await Task.detached { Result { () -> (CommandResult, [Device]) in
                let connection = try client.run(["connect", endpoint.address], timeout: 12)
                return (connection, try client.enrichedDevices())
            } }.value
            switch result {
            case .success(let (connection, value)):
                log(connection.output); updateDevices(value)
                if let match = value.first(where: { $0.serial == endpoint.address }) {
                    selectedSerial = match.serial
                    if match.ready { notice("已连接 \(match.title)，可以开始安装。") }
                    else { notice(ADBParser.friendlyError(match.state), error: true) }
                } else { notice(ADBParser.friendlyError(connection.output), error: true) }
            case .failure(let error): notice(error.localizedDescription, error: true)
            }
            busy = false; phase = "准备就绪"
        }
    }

    func discover() {
        guard !busy else { return }
        guard let network else { notice("未发现可用的局域网，请检查 Mac 的 Wi-Fi 或网线连接。", error: true); return }
        busy = true; phase = "正在发现设备"; progress = 0
        log("扫描 \(network.description) 的 TCP 5555，并检查无线 ADB 广播。")
        let client = self.client
        Task {
            let result = await Task.detached { [weak self] in Result { () -> ([Device], Int) in
                _ = try client.run(["start-server"])
                let hosts = PortProbe.scan(network) { done, total in
                    Task { @MainActor [weak self] in self?.progress = total > 0 ? Double(done) / Double(total) : 1 }
                }
                let services = try client.run(["mdns", "services"], timeout: 8)
                let endpoints = Set(hosts.map { "\($0):5555" } + ADBParser.services(services.output).map(\.address))
                for endpoint in endpoints.sorted() { _ = try client.run(["connect", endpoint], timeout: 8) }
                return (try client.enrichedDevices(), endpoints.count)
            } }.value
            switch result {
            case .success(let (value, count)):
                updateDevices(value)
                if value.contains(where: \.ready) { notice("发现 \(value.filter(\.ready).count) 台已连接设备。请确认型号并选择安装目标。") }
                else if !value.isEmpty { notice("已发现 ADB 设备，请在设备上允许调试，再刷新状态。", error: true) }
                else { notice(count == 0 ? "未发现网络 ADB。可输入设备 IP 重试，或在设备的无线调试页面查看端口并配对。" : "发现开放的端口，但连接失败。可打开「诊断与终端」检查授权和本机 ADB 服务。", error: true) }
            case .failure(let error): notice(error.localizedDescription, error: true)
            }
            busy = false; progress = 1; phase = "发现完成"
        }
    }

    func pair() {
        guard !busy else { return }
        let pairing: Endpoint
        let connection: Endpoint
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard pairAddress.contains(":"), connectionAddress.contains(":") else { throw ToolError.message("请分别填写设备显示的配对地址和连接地址（含端口）。") }
            pairing = try Endpoint(pairAddress)
            connection = try Endpoint(connectionAddress)
            guard code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message("请输入设备上显示的 6 位配对码。") }
        } catch { notice(error.localizedDescription, error: true); return }
        busy = true; phase = "正在配对"; progress = 0
        let client = self.client
        Task {
            let result = await Task.detached { Result { try client.run(["pair", pairing.address], timeout: 25, input: code) } }.value
            pairCode = ""; busy = false
            switch result {
            case .success(let value):
                // Pairing codes are never included in logs or persisted.
                if value.success && value.output.contains("Successfully paired") {
                    showPairing = false; address = connection.address
                    notice("配对成功，正在连接设备。")
                    connect(connection.address)
                } else { notice("配对失败。请确认配对窗口仍打开、地址和端口正确，配对码未过期。", error: true); phase = "配对未完成" }
            case .failure(let error): notice(error.localizedDescription, error: true); phase = "配对未完成"
            }
        }
    }

    func disconnect() {
        guard !busy, let target = selected else { return }
        busy = true; phase = "正在断开连接"
        let client = self.client
        Task {
            let result = await Task.detached { Result { () -> [Device] in
                let outcome = try client.run(["disconnect", target.serial])
                guard outcome.success else { throw ToolError.message(ADBParser.friendlyError(outcome.output)) }
                return try client.enrichedDevices()
            } }.value
            switch result {
            case .success(let value): updateDevices(value); notice("已断开 \(target.title)。如需关闭调试服务，请在设备设置中关闭 ADB。")
            case .failure(let error): notice(error.localizedDescription, error: true)
            }
            busy = false; phase = "准备就绪"
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要安装的 APK"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func addFiles(_ urls: [URL]) {
        guard !installing else { return }
        var rejected: [String] = []
        for url in urls {
            let resolved = url.standardizedFileURL
            guard !files.contains(where: { $0.url == resolved }) else { continue }
            do {
                try ADBParser.validateAPK(resolved)
                let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                files.append(APKItem(url: resolved, size: Int64(size)))
            } catch { rejected.append(error.localizedDescription) }
        }
        if !rejected.isEmpty { notice(rejected.joined(separator: "\n"), error: true) }
        else if !urls.isEmpty { notice("已选择 \(files.count) 个 APK。安装前请确认目标设备。") }
    }

    func install() {
        guard canInstall, let target = selected else { return }
        let items = files
        let split = splitMode
        busy = true; installing = true; cancelRemaining = false; progress = 0
        files.indices.forEach { files[$0].state = "待安装"; files[$0].detail = "" }
        let client = self.client
        log("安装目标：\(target.title) · \(target.serial)。模式：\(split ? "同一应用的拆分 APK" : "独立 APK 队列")。")
        Task {
            var successes = 0
            var failures = 0
            let groups = split ? [items] : items.map { [$0] }
            for (index, group) in groups.enumerated() {
                if cancelRemaining { break }
                phase = split ? "安装拆分 APK" : "正在安装 \(index + 1) / \(groups.count)"
                let ids = Set(group.map(\.id))
                for i in files.indices where ids.contains(files[i].id) { files[i].state = "安装中" }
                log("开始安装：\(group.map { $0.url.lastPathComponent }.joined(separator: "、"))")
                let result = await Task.detached { Result { () -> CommandResult in
                    // Check the selected target again. Never fall back to another connected device.
                    let state = try client.run(["-s", target.serial, "get-state"], timeout: 8)
                    guard state.success, state.output.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else {
                        throw ToolError.message(ADBParser.friendlyError(state.output))
                    }
                    let args = try ADBParser.installArguments(serial: target.serial, files: group.map(\.url), split: split)
                    return try client.run(args, timeout: 600)
                } }.value
                let success: Bool
                let detail: String
                switch result {
                case .success(let value):
                    log(value.output)
                    success = value.success && value.output.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" })
                    detail = success ? "已安装到 \(target.title)" : ADBParser.friendlyError(value.output)
                case .failure(let error): success = false; detail = error.localizedDescription; log(detail)
                }
                for i in files.indices where ids.contains(files[i].id) { files[i].state = success ? "安装成功" : "安装失败"; files[i].detail = detail }
                if success {
                    let completed = files.filter { ids.contains($0.id) }
                    installedFiles.append(contentsOf: completed.map { InstalledAPKItem(name: $0.url.lastPathComponent, size: $0.size, target: "\(target.title) · \(target.serial)") })
                    files.removeAll { ids.contains($0.id) }
                    successes += 1
                } else { failures += 1 }
                progress = Double(index + 1) / Double(groups.count)
            }
            if cancelRemaining {
                for i in files.indices where files[i].state == "待安装" { files[i].state = "已跳过" }
            }
            installing = false; busy = false
            phase = cancelRemaining ? "队列已停止" : "安装完成"
            notice("\(phase)：成功 \(successes) 项，失败 \(failures) 项。\(successes > 0 ? "可在设备的应用列表中打开。" : "")", error: failures > 0)
        }
    }

    func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "安卓设备安装日志.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let content = logs.map { "[\(formatter.string(from: $0.date))] \($0.text)" }.joined(separator: "\n\n")
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { notice("日志导出失败：\(error.localizedDescription)", error: true) }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ink.opacity(0.06), lineWidth: 1))
    }
}

struct SectionTitle: View {
    let number: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            Text(number).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(accent).frame(width: 30, height: 30)
                .background(accent.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(.white).background(enabled ? accent.opacity(configuration.isPressed ? 0.75 : 1) : muted.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct InstallerView: View {
    @EnvironmentObject var model: InstallerModel
    @State var showHelp = false
    @State var showPreparation = false
    @State var toolsTarget: Device?
    @State var toolsSection = 0
    @State var showTroubleshooting = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    deviceCard
                    apkCard
                    installedCard
                    statusCard
                    HStack {
                        Label("官方 ADB · 文件经局域网直接传到设备", systemImage: "network")
                        Spacer()
                        Button("使用帮助") { showHelp = true }.buttonStyle(.plain).foregroundStyle(accent)
                        Button("查看日志") { model.showLogs = true }.buttonStyle(.plain).foregroundStyle(accent)
                    }.font(.system(size: 11)).foregroundStyle(muted).padding(.horizontal, 4)
                }.padding(28)
            }.background(canvas)
        }
        .frame(minWidth: 1000, minHeight: 740)
        .foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
        .sheet(isPresented: $model.showPairing) { pairingSheet }
        .sheet(isPresented: $model.showLogs) { logSheet }
        .sheet(isPresented: $showHelp) { helpSheet }
        .sheet(isPresented: $showPreparation) { PreparationGuideView() }
        .sheet(item: $toolsTarget) { target in DeviceToolsView(target: target, client: model.client, section: toolsSection) }
        .sheet(isPresented: $showTroubleshooting, onDismiss: { model.refresh() }) {
            TroubleshootingView(client: model.client, address: model.selected?.serial ?? model.address,
                                initialOutput: model.logs.map { "[\($0.date.formatted())] \($0.text)" }.joined(separator: "\n"))
        }
        .onOpenURL { model.addFiles([$0]) }
        .onAppear { model.refresh() }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "apps.iphone").font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(accent).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("安卓设备安装助手").font(.system(size: 13, weight: .bold))
                    Text("ANDROID LAN INSTALLER").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.1).foregroundStyle(muted)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("安装应用", systemImage: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
                Button { showPreparation = true } label: { Label("连接前准备教程", systemImage: "book.closed").padding(.horizontal, 13) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(muted)
                ForEach(Array([("设备应用", "apps.iphone"), ("虚拟遥控器", "dpad"), ("一键截图", "camera")].enumerated()), id: \.offset) { index, item in
                    Button { toolsSection = index; toolsTarget = model.selected } label: { Label(item.0, systemImage: item.1).padding(.horizontal, 13) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(muted).disabled(model.busy || model.selected?.ready != true)
                }
                Button { model.showLogs = true } label: { Label("操作日志", systemImage: "text.alignleft").padding(.horizontal, 13) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(muted)
                Button { showTroubleshooting = true } label: { Label("诊断与终端", systemImage: "terminal").padding(.horizontal, 13) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(muted).disabled(model.busy)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Text("开始前，设备上准备好").font(.system(size: 12, weight: .semibold))
                hint("1", "开启网络 ADB / 无线调试")
                hint("2", "连接同一个局域网")
                hint("3", "允许此电脑调试")
                Divider().padding(.vertical, 4)
                HStack(spacing: 6) {
                    Circle().fill(model.networks.isEmpty ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.networks.isEmpty ? "未连接局域网" : "局域网已连接").font(.system(size: 11))
                }
                Text(model.network?.ip ?? "检查 Wi-Fi / 以太网").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
            }
            Text("v1.5.0 · macOS").font(.system(size: 10)).foregroundStyle(muted.opacity(0.75))
        }.padding(24).frame(width: 220).background(Color.white)
            .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.06)).frame(width: 1) }
    }

    func hint(_ number: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, weight: .medium)).frame(width: 19, height: 19).background(canvas).clipShape(Circle())
            Text(text).font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("把喜欢的应用，装上设备。").font(.system(size: 25, weight: .bold))
                Text("发现设备，选择 APK，一键安装。").font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Label("手机 / 平板 / 电视 / 机顶盒", systemImage: "wifi")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                .padding(.horizontal, 12).padding(.vertical, 8).background(.white).clipShape(Capsule())
        }.padding(.bottom, 3)
    }

    var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionTitle(number: "01", title: "选择设备", subtitle: "仅连接已开启网络 ADB 的设备")
                    Button("准备教程") { showPreparation = true }.buttonStyle(.borderless).font(.system(size: 11))
                    Spacer()
                    Button { model.refresh() } label: { Label("刷新状态", systemImage: "arrow.clockwise") }
                        .disabled(model.busy).buttonStyle(.borderless).font(.system(size: 11))
                    Button("诊断与终端") { showTroubleshooting = true }.disabled(model.busy).buttonStyle(.borderless).font(.system(size: 11))
                }
                HStack(spacing: 10) {
                    Picker("网络", selection: $model.networkID) {
                        if model.networks.isEmpty { Text("暂无网络").tag("") }
                        ForEach(model.networks) { Text($0.description).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(model.busy)
                    Button { model.discover() } label: { Label("发现设备", systemImage: "antenna.radiowaves.left.and.right") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
                }
                if model.busy && !model.installing {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: model.progress).tint(accent)
                        Text(model.phase).font(.system(size: 10)).foregroundStyle(muted)
                    }
                }
                if !model.devices.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.devices) { device in deviceTile(device) }
                    }
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: "tv").font(.system(size: 26)).foregroundStyle(muted.opacity(0.5))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("等待发现你的设备").font(.system(size: 12, weight: .medium))
                            Text("没有发现？在下方输入设备的 IP 地址。").font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                    }.padding(18).background(canvas).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(muted)
                    TextField("设备 IP，例如 192.168.1.73 或 IP:端口", text: $model.address)
                        .textFieldStyle(.roundedBorder).onSubmit { model.connect() }.disabled(model.busy)
                    Button("连接") { model.connect() }.disabled(model.busy || model.address.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("无线配对") { model.showPairing = true }.disabled(model.busy)
                }.font(.system(size: 11))
                HStack {
                    Text(model.network?.scanDescription ?? "请选择网络后发现设备，也可手动连接。")
                    Spacer()
                    if model.selected != nil { Button("断开所选设备") { model.disconnect() }.buttonStyle(.plain).foregroundStyle(muted).disabled(model.busy) }
                }.font(.system(size: 10)).foregroundStyle(muted)
            }
        }
    }

    func deviceTile(_ device: Device) -> some View {
        let selected = model.selectedSerial == device.serial
        return Button { model.selectedSerial = device.serial } label: {
            HStack(spacing: 12) {
                Image(systemName: "apps.iphone").font(.system(size: 22)).foregroundStyle(selected ? accent : muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(device.serial).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(device.ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                        Text(device.status + (device.android.isEmpty ? "" : " · Android \(device.android)"))
                            .font(.system(size: 10)).foregroundStyle(muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? accent : muted.opacity(0.3))
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? accent.opacity(0.04) : canvas.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent : ink.opacity(0.08), lineWidth: 1))
        }.buttonStyle(.plain).disabled(model.busy)
    }

    var apkCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionTitle(number: "02", title: "添加应用", subtitle: "支持单个 APK、批量安装和同一应用的拆分 APK")
                    Spacer()
                    if !model.files.isEmpty { Button("清空") { model.files.removeAll() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.installing) }
                }
                Button { model.chooseFiles() } label: {
                    HStack(spacing: 15) {
                        Image(systemName: "shippingbox").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("拖入 APK，或点击选择文件").font(.system(size: 13, weight: .semibold))
                            Text("可一次选择多个文件 · 从应用官方来源获取适合目标设备的 APK").font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").font(.system(size: 23)).foregroundStyle(accent)
                    }.padding(21).frame(maxWidth: .infinity).background(model.hovered ? accent.opacity(0.1) : accent.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }.buttonStyle(.plain).disabled(model.installing)
                    .onDrop(of: [UTType.fileURL], isTargeted: $model.hovered) { providers in
                        guard !model.installing else { return false }
                        for provider in providers {
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                if let url { Task { @MainActor in model.addFiles([url]) } }
                            }
                        }
                        return true
                    }
                if !model.files.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(model.files) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.state == "安装成功" ? "checkmark.circle.fill" : item.state == "安装失败" ? "exclamationmark.circle.fill" : "doc.zipper")
                                    .foregroundStyle(item.state == "安装成功" ? Color.green : item.state == "安装失败" ? Color.red : muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(item.url.path)
                                    if !item.detail.isEmpty { Text(item.detail).font(.system(size: 10)).foregroundStyle(item.state == "安装失败" ? Color.red : muted).fixedSize(horizontal: false, vertical: true) }
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(muted).font(.system(size: 10))
                                Text(item.state).foregroundStyle(item.state == "安装成功" ? Color.green : item.state == "安装失败" ? Color.red : muted).font(.system(size: 10))
                                Button { model.files.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.plain).foregroundStyle(muted).disabled(model.installing)
                            }.padding(.vertical, 10)
                            if item.id != model.files.last?.id { Divider() }
                        }
                    }
                }
                HStack {
                    Toggle("拆分 APK（所有文件属于同一应用）", isOn: $model.splitMode)
                        .font(.system(size: 11)).toggleStyle(.checkbox).disabled(model.installing)
                    Spacer()
                    Text("覆盖更新，保留应用数据").font(.system(size: 10)).foregroundStyle(muted)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selected.map { "安装到：\($0.title)" } ?? "请先连接并选择设备")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.selected?.serial ?? "安装目标将在此显示").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    }
                    Spacer()
                    if model.installing {
                        ProgressView().controlSize(.small)
                        Button(model.cancelRemaining ? "将停止后续安装" : "停止后续安装") { model.cancelRemaining = true }
                            .disabled(model.cancelRemaining).font(.system(size: 11))
                    }
                    Button { model.install() } label: {
                        Label(model.installing ? model.phase : "开始安装\(model.files.isEmpty ? "" : " · \(model.files.count) 个 APK")", systemImage: "arrow.down.to.line")
                    }.buttonStyle(PrimaryButtonStyle()).disabled(!model.canInstall)
                }
                if model.installing { ProgressView(value: model.progress).tint(accent) }
            }
        }
    }

    var installedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(number: "03", title: "已安装", subtitle: "本次会话的成功记录，不会参与后续安装")
                    Spacer()
                    if !model.installedFiles.isEmpty {
                        Button("清空记录") { model.installedFiles.removeAll() }.buttonStyle(.borderless)
                            .font(.system(size: 11)).disabled(model.installing).help("只清空记录，不卸载目标设备的应用")
                    }
                }
                if model.installedFiles.isEmpty {
                    Text("安装成功的 APK 会自动移到这里，失败或未安装的文件仍留在添加应用。")
                        .font(.system(size: 11)).foregroundStyle(muted)
                } else {
                    ForEach(model.installedFiles.reversed()) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(item.name)
                                Text(item.target).font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled)
                                if let date = item.date {
                                    Text(date, format: .dateTime.month().day().hour().minute().second()).font(.system(size: 10)).foregroundStyle(muted)
                                } else {
                                    Text("旧版会话的成功记录").font(.system(size: 10)).foregroundStyle(muted)
                                }
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(muted)
                            Text("安装成功").font(.system(size: 10)).foregroundStyle(.green)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }
    }

    var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.bannerError ? "exclamationmark.circle" : "info.circle").font(.system(size: 14))
            Text(model.banner).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.foregroundStyle(model.bannerError ? Color(red: 0.62, green: 0.30, blue: 0.08) : muted)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.bannerError ? Color.orange.opacity(0.08) : ink.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    var pairingSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("无线调试配对").font(.system(size: 22, weight: .bold))
            Text("在设备「开发者选项 → 无线调试」中选择「使用配对码配对」。保持配对窗口打开，分别填写配对地址和无线调试主页面的连接地址。两者端口通常不同。")
                .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            labeledField("配对 IP 与端口", placeholder: "192.168.1.73:37001", text: $model.pairAddress)
            VStack(alignment: .leading, spacing: 6) {
                Text("6 位配对码").font(.system(size: 11, weight: .medium))
                SecureField("设备显示的配对码", text: $model.pairCode).textFieldStyle(.roundedBorder)
            }
            labeledField("连接 IP 与端口", placeholder: "192.168.1.73:39001", text: $model.connectionAddress)
            if model.bannerError { Text(model.banner).font(.system(size: 11)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("没有此菜单的设备，使用主界面的 IP 连接。").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Button("取消") { model.showPairing = false; model.pairCode = "" }.disabled(model.busy)
                Button("配对并连接") { model.pair() }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
            }
        }.padding(28).frame(width: 570).background(canvas)
    }

    func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    var logSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("操作日志").font(.system(size: 20, weight: .bold))
                Spacer()
                Button("导出日志") { model.exportLogs() }
                Button("关闭") { model.showLogs = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.logs.isEmpty { Text("暂无操作记录").foregroundStyle(muted) }
                    ForEach(model.logs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.date, style: .time).foregroundStyle(muted).font(.system(size: 10, design: .monospaced))
                            Text(entry.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                    }
                }.padding(15)
            }.background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
            Text("日志仅保存在当前会话；导出后可查看具体的 ADB 错误信息。").font(.system(size: 10)).foregroundStyle(muted)
        }.padding(24).frame(width: 760, height: 500).background(canvas)
    }

    var helpSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("使用帮助").font(.system(size: 22, weight: .bold)); Spacer(); Button("关闭") { showHelp = false } }
            Button("打开连接前准备教程") { showHelp = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showPreparation = true } }
            helpItem("1. 准备设备", "在设备设置中启用开发者选项，再开启无线调试或网络 ADB。通常连续点击「版本号」启用开发者选项，菜单随品牌和系统而变化。部分设备需先通过 USB 启用网络 ADB。")
            helpItem("2. 连接", "电脑和设备连接同一局域网。点击发现设备，或输入设备网络详情里的 IP。默认端口 5555；无线调试以设备显示的端口为准。首次连接需在设备上允许调试。")
            helpItem("3. 安装", "拖入或选择 APK，确认设备型号及 IP，再开始安装。多个独立 APK 会依次安装；同一应用的 base 和 split 文件需勾选拆分 APK。请确认 APK 支持目标设备的 Android 版本、处理器架构与操作方式。")
            helpItem("找不到设备", "确认设备已开机、IP 正确、没有使用访客网络。部分固件开启 ADB 后仍未开放网络端口；本工具无法远程开启设备端的调试服务。大于 /24 的网络仅扫描本机所在 /24，其他网段使用手动 IP。若 macOS 提示局域网权限，请允许；拒绝后到系统设置 → 隐私与安全性 → 本地网络恢复。")
            helpItem("安装报错", "查看操作日志和每个文件下的原因。签名不同、版本过旧、存储不足或缺少 split 文件都可能导致失败。本工具不会自动卸载应用或删除设备数据。")
            helpItem("使用后", "断开连接只断开这台电脑；需要关闭调试服务时，请在设备设置中关闭 ADB。配对码不保存，ADB 的设备信任密钥由官方 ADB 管理。")
        }.padding(28).frame(width: 650).background(canvas)
    }

    func helpItem(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.troubleshooting?.stop()
        if let model = AppState.model, model.installing {
            let alert = NSAlert()
            alert.messageText = "安装仍在进行"
            alert.informativeText = "退出会停止后续安装。设备可能仍会完成当前安装，请在设备上确认结果。"
            alert.addButton(withTitle: "继续安装")
            alert.addButton(withTitle: "退出")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        return .terminateNow
    }
}

enum AppState { @MainActor static weak var model: InstallerModel?; @MainActor static weak var troubleshooting: TroubleshootingModel? }

#if !QUEUE_TESTING
@main
@MainActor
struct TVInstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = InstallerModel()
    var body: some Scene {
        WindowGroup("局域网安卓设备安装助手") {
            InstallerView().environmentObject(model).onAppear { AppState.model = model }
        }.defaultSize(width: 1140, height: 830)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("选择 APK…") { model.chooseFiles() }.keyboardShortcut("o").disabled(model.installing)
                }
                CommandGroup(after: .newItem) {
                    Button("发现设备") { model.discover() }.keyboardShortcut("r").disabled(model.busy)
                    Button("操作日志") { model.showLogs = true }.keyboardShortcut("l")
                }
            }
    }
}

#endif
