import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ManagedApp: Identifiable {
    let package: String
    let system: Bool
    var id: String { package }
}

@MainActor final class DeviceToolsModel: ObservableObject {
    let target: Device
    let client: ADBClient
    @Published var apps: [ManagedApp] = []
    @Published var includeSystem = false
    @Published var filter = ""
    @Published var selected: String?
    @Published var busy = false
    @Published var message = "点击刷新，读取当前用户的设备应用。列表按应用包名显示。"
    @Published var failed = false
    @Published var screenshot: Data?
    var visible: [ManagedApp] { apps.filter { filter.isEmpty || $0.package.localizedCaseInsensitiveContains(filter) } }
    var chosen: ManagedApp? { apps.first { $0.package == selected } }
    init(target: Device, client: ADBClient) { self.target = target; self.client = client }
    func perform(_ title: String, work: @escaping () throws -> String, completion: ((String) -> Void)? = nil) {
        guard !busy else { return }
        busy = true; message = title; failed = false
        Task {
            let result = await Task.detached { Result { try work() } }.value
            switch result {
            case .success(let text): completion?(text); message = title + "完成"; failed = false
            case .failure(let error): message = ADBParser.friendlyError(error.localizedDescription); failed = true
            }
            busy = false
        }
    }
    func refresh() {
        let client = client, serial = target.serial, all = includeSystem
        perform("读取设备应用", work: {
            let third = try client.toolShell(serial, "pm list packages -3 --user current")
            let every = all ? try client.toolShell(serial, "pm list packages --user current") : third
            return third + "\n__ALL__\n" + every
        }) { output in
            let parts = output.components(separatedBy: "\n__ALL__\n")
            let third = Set(DeviceCommands.packages(parts[0]))
            self.apps = DeviceCommands.packages(parts[1]).map { ManagedApp(package: $0, system: !third.contains($0)) }
            if !self.apps.contains(where: { $0.package == self.selected }) { self.selected = nil }
        }
    }
    func launch() {
        guard let app = chosen else { return }
        let client = client, serial = target.serial
        perform("打开应用", work: {
            let pkg = try DeviceCommands.package(app.package)
            for category in ["LEANBACK_LAUNCHER", "LAUNCHER"] {
                let output = try client.toolShell(serial, "cmd package resolve-activity --brief --user current -a android.intent.action.MAIN -c android.intent.category." + category + " " + pkg)
                if let component = DeviceCommands.component(output), component.hasPrefix(pkg + "/") {
                    return try client.toolShell(serial, "am start --user current -n '" + component + "'")
                }
            }
            throw ToolError.message("此应用没有可打开的电视或手机桌面入口。")
        })
    }
    func action(_ kind: String) {
        guard let app = chosen else { return }
        if kind != "强制停止", app.system { message = "系统应用仅提供查看和打开，不提供卸载。"; failed = true; return }
        let client = client, serial = target.serial
        perform(kind, work: {
            let pkg = try DeviceCommands.package(app.package)
            let command = kind == "卸载" ? "pm uninstall --user current " : kind == "清除数据" ? "pm clear --user current " : "am force-stop --user current "
            let output = try client.toolShell(serial, command + pkg)
            if kind != "强制停止", output != "Success" { throw ToolError.message(output.isEmpty ? "设备未确认操作成功。" : output) }
            return output
        }) { _ in if kind == "卸载" { self.apps.removeAll { $0.package == app.package }; self.selected = nil } }
    }
    func key(_ code: String) {
        let client = client, serial = target.serial
        perform("发送按键", work: { try client.toolShell(serial, DeviceCommands.key(code)) })
    }
    func capture() {
        guard !busy else { return }
        busy = true; failed = false; message = "正在截取设备画面…"
        let client = client, serial = target.serial
        Task {
            let result = await Task.detached { Result { try client.screenshot(serial) } }.value
            switch result {
            case .success(let data): screenshot = data; message = "截图完成，可以保存到电脑。"
            case .failure(let error): failed = true; message = ADBParser.friendlyError(error.localizedDescription)
            }
            busy = false
        }
    }
    func save() {
        guard let data = screenshot else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "设备截图.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); message = "截图已保存。"; failed = false }
        catch { message = error.localizedDescription; failed = true }
    }
}

struct DeviceToolsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject var model: DeviceToolsModel
    @State var section: Int
    @State private var confirm: String?
    init(target: Device, client: ADBClient, section: Int = 0) {
        _model = StateObject(wrappedValue: DeviceToolsModel(target: target, client: client)); _section = State(initialValue: section)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("设备工具").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.disabled(model.busy) }
            Text(model.target.title + " · " + model.target.serial).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
            Picker("功能", selection: $section) { Text("设备应用").tag(0); Text("虚拟遥控器").tag(1); Text("截图").tag(2) }.pickerStyle(.segmented)
            if section == 0 { apps } else if section == 1 { remote } else { screen }
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.message).font(.system(size: 12)).foregroundStyle(model.failed ? Color.red : muted).textSelection(.enabled) }
        }.padding(24).frame(width: 760, height: 610).tint(accent).preferredColorScheme(.light)
            .alert(confirm ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("取消", role: .cancel) { confirm = nil }
                Button("确认", role: .destructive) { let kind = confirm!; confirm = nil; model.action(kind) }
            } message: {
                Text("目标：\(model.target.title) · \(model.target.serial)\n应用：\(model.chosen?.package ?? "")\n\(confirm == "卸载" ? "卸载会删除应用及其数据。" : "会删除登录状态、设置和本地数据，不只是清缓存。")")
            }
    }
    var apps: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索应用包名", text: $model.filter).textFieldStyle(.roundedBorder)
                Toggle("包含系统应用", isOn: Binding(get: { model.includeSystem }, set: { model.includeSystem = $0; model.refresh() })).disabled(model.busy)
                Button("刷新") { model.refresh() }.disabled(model.busy)
            }
            List(selection: $model.selected) {
                ForEach(model.visible) { app in HStack { Text(app.package); Spacer(); Text(app.system ? "系统应用" : "用户应用").foregroundStyle(muted).font(.caption) }.tag(app.package) }
            }.disabled(model.busy)
            HStack {
                Text("\(model.visible.count) 个应用 · 当前用户").font(.caption).foregroundStyle(muted); Spacer()
                Button("打开") { model.launch() }
                Button("强制停止") { model.action("强制停止") }
                Button("清除数据") { confirm = "清除数据" }.disabled(model.chosen?.system != false)
                Button("卸载", role: .destructive) { confirm = "卸载" }.disabled(model.chosen?.system != false)
            }.disabled(model.busy || model.chosen == nil)
        }
    }
    var remote: some View {
        VStack(spacing: 18) {
            Text("控制所选设备的按键。部分设备需额外开启“允许模拟输入”。").font(.caption).foregroundStyle(muted)
            VStack(spacing: 10) {
                remoteButton("上", "KEYCODE_DPAD_UP")
                HStack(spacing: 10) { remoteButton("左", "KEYCODE_DPAD_LEFT"); remoteButton("确认", "KEYCODE_DPAD_CENTER"); remoteButton("右", "KEYCODE_DPAD_RIGHT") }
                remoteButton("下", "KEYCODE_DPAD_DOWN")
            }
            HStack(spacing: 10) { remoteButton("返回", "KEYCODE_BACK"); remoteButton("主页", "KEYCODE_HOME") }
            HStack(spacing: 10) { remoteButton("音量 −", "KEYCODE_VOLUME_DOWN"); remoteButton("音量 +", "KEYCODE_VOLUME_UP") }
        }.frame(maxWidth: .infinity).padding(.top, 18).disabled(model.busy)
    }
    func remoteButton(_ title: String, _ code: String) -> some View { Button(title) { model.key(code) }.buttonStyle(PrimaryButtonStyle()).frame(minWidth: 86) }
    var screen: some View {
        VStack(spacing: 12) {
            HStack { Button("截取画面") { model.capture() }.disabled(model.busy); Button("保存截图…") { model.save() }.disabled(model.screenshot == nil || model.busy); Spacer() }
            if let data = model.screenshot, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 360) }
            else { Text("点击截取画面，预览后保存为 PNG。受保护的内容可能显示为黑色。").foregroundStyle(muted).frame(maxWidth: .infinity, minHeight: 280) }
        }
    }
}
