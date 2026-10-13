using System.Text;

namespace TVAppInstaller;

public class MainForm : Form
{
    static readonly Color Orange = Color.FromArgb(235, 88, 34), Ink = Color.FromArgb(35, 45, 50), Background = Color.FromArgb(247, 247, 242);
    readonly AdbClient adb = new(Path.Combine(AppContext.BaseDirectory, "Resources", "adb", "adb.exe"));
    readonly ComboBox networks = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly ComboBox devices = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly TextBox address = new() { PlaceholderText = "设备 IP，例如 192.168.1.100 或 IP:端口", Dock = DockStyle.Fill };
    readonly Label status = new() { AutoSize = true, MaximumSize = new Size(950, 0), ForeColor = Ink };
    readonly ProgressBar progress = new() { Dock = DockStyle.Fill, Height = 5, Maximum = 1000 };
    readonly DataGridView queue = new() { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = Color.White, BorderStyle = BorderStyle.None, AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells };
    readonly CheckBox split = new() { Text = "拆分 APK（所有文件属于同一应用）", AutoSize = true };
    readonly TextBox logs = new() { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9), WordWrap = true };
    readonly List<string> paths = [];
    readonly DataGridView installedRows = new() { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells, BackgroundColor = Color.White, BorderStyle = BorderStyle.None };
    readonly List<Control> locked = [];
    readonly Button install, stop;
    bool busy, installing, stopRemaining;

    public MainForm(string[] initial)
    {
        Text = "局域网安卓设备安装助手 · Windows"; Size = new Size(1060, 1040); MinimumSize = new Size(900, 920);
        StartPosition = FormStartPosition.CenterScreen; BackColor = Background; ForeColor = Ink;
        Font = new Font("Microsoft YaHei UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(26), ColumnCount = 1, RowCount = 7 };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 76));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 220));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 48));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 25));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 65));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 27));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        Controls.Add(root);
        root.Controls.Add(new Label { Text = "把喜欢的应用，装上设备。\n发现设备，选择 APK，一键安装。", AutoSize = true, Font = new Font(Font.FontFamily, 18, FontStyle.Bold), Padding = new Padding(0, 0, 0, 12) }, 0, 0);

        var connection = Card(5);
        root.Controls.Add(connection, 0, 1);
        connection.Controls.Add(Row(new Label { Text = "01  选择设备   ·   设备开启网络 ADB，与电脑接入同一局域网", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, Button("准备教程", Preparation, tracked: false)), 0, 0);
        var networkLine = Row(networks, Button("发现设备", Discover, true), Button("刷新状态", RefreshDevices));
        connection.Controls.Add(networkLine, 0, 1);
        connection.Controls.Add(devices, 0, 2);
        connection.Controls.Add(Row(address, Button("连接", Connect), Button("无线配对", Pair), Button("断开", Disconnect)), 0, 3);
        connection.Controls.Add(new Label { Text = "扫描所选局域网的 5555 端口与无线 ADB 广播。大网络最多扫描本机所在 /24。", AutoSize = true, ForeColor = Color.DimGray }, 0, 4);
        locked.AddRange([networks, devices, address]);

        var apk = Card(4); root.Controls.Add(apk, 0, 2);
        apk.RowStyles.Clear(); apk.RowStyles.Add(new RowStyle(SizeType.Absolute, 34)); apk.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); apk.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); apk.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        apk.Controls.Add(new Label { Text = "02  添加应用   ·   拖入 APK 或选择文件", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, 0, 0);
        apk.Controls.Add(Row(new Label { Text = "APK 从电脑直接发送到所选设备，不上传云端。", AutoSize = true }, Button("选择 APK…", Choose), Button("移除所选", Remove), Button("清空", Clear)), 0, 1);
        queue.Columns.Add("file", "APK 文件"); queue.Columns.Add("size", "大小"); queue.Columns.Add("state", "状态 / 结果");
        queue.Columns[0]!.FillWeight = 40; queue.Columns[1]!.FillWeight = 12; queue.Columns[2]!.FillWeight = 48;
        queue.DefaultCellStyle.WrapMode = DataGridViewTriState.True; queue.RowTemplate.Height = 32;
        queue.DefaultCellStyle.SelectionBackColor = Color.FromArgb(255, 231, 219); queue.DefaultCellStyle.SelectionForeColor = Ink;
        queue.AllowDrop = true;
        queue.DragEnter += (_, e) => { if (!busy && e.Data?.GetDataPresent(DataFormats.FileDrop) == true) e.Effect = DragDropEffects.Copy; };
        queue.DragDrop += (_, e) => { if (!busy && e.Data?.GetData(DataFormats.FileDrop) is string[] files) AddFiles(files); };
        apk.Controls.Add(queue, 0, 2);
        install = Button("开始安装", Install, true); stop = Button("停止后续安装", StopQueue, tracked: false); stop.Enabled = false;
        apk.Controls.Add(Row(split, new Label { Text = "覆盖更新，保留应用数据", AutoSize = true }, stop, install), 0, 3); locked.Add(split);

        var historyCard = Card(2); historyCard.RowStyles.Clear(); historyCard.RowStyles.Add(new RowStyle(SizeType.Absolute, 40)); historyCard.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        historyCard.Controls.Add(Row(new Label { Text = "03  已安装 · 本次会话的成功记录，不会参与后续安装", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, Button("清空记录", ClearInstalled, tracked: false)), 0, 0);
        installedRows.Columns.Add("file", "APK 文件"); installedRows.Columns.Add("size", "大小"); installedRows.Columns.Add("target", "安装目标"); installedRows.Columns.Add("time", "完成时间");
        installedRows.Columns[0].FillWeight = 32; installedRows.Columns[1].FillWeight = 12; installedRows.Columns[2].FillWeight = 36; installedRows.Columns[3].FillWeight = 20;
        installedRows.DefaultCellStyle.WrapMode = DataGridViewTriState.True; installedRows.DefaultCellStyle.ForeColor = Color.ForestGreen; historyCard.Controls.Add(installedRows, 0, 1); root.Controls.Add(historyCard, 0, 3);

        var statusPanel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2 };
        statusPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 48)); statusPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 8));
        statusPanel.Controls.Add(status); statusPanel.Controls.Add(progress); root.Controls.Add(statusPanel, 0, 4);
        var logCard = Card(2); logCard.RowStyles.Clear(); logCard.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); logCard.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        logCard.Controls.Add(Row(new Label { Text = "操作日志", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, Button("导出日志", Export, tracked: false), Button("准备教程", Preparation, tracked: false), Button("使用帮助", Help, tracked: false)), 0, 0);
        logCard.Controls.Add(logs, 0, 1); root.Controls.Add(logCard, 0, 5);
        root.Controls.Add(new Label { Text = "v1.3.0  ·  官方 ADB  ·  Windows 10 / 11", ForeColor = Color.DimGray, AutoSize = true }, 0, 6);
        Shown += async (_, _) => { AddFiles(initial); LoadNetworks(); await Guard(RefreshDevices); };
        devices.SelectedIndexChanged += (_, _) => UpdateInstall();
        FormClosing += (_, e) => { if (installing && MessageBox.Show("安装仍在进行。退出会停止后续队列，当前安装结果需在设备上确认。是否退出？", Text, MessageBoxButtons.YesNo) != DialogResult.Yes) e.Cancel = true; };
    }

    TableLayoutPanel Card(int rows) => new() { Dock = DockStyle.Fill, Padding = new Padding(16), Margin = new Padding(0, 0, 0, 14), BackColor = Color.White, ColumnCount = 1, RowCount = rows };
    TableLayoutPanel Row(params Control[] controls)
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 1, ColumnCount = controls.Length, Margin = new Padding(0, 4, 0, 4), AutoSize = true };
        for (int i = 0; i < controls.Length; i++) { panel.ColumnStyles.Add(new ColumnStyle(i == 0 ? SizeType.Percent : SizeType.AutoSize, i == 0 ? 100 : 0)); controls[i].Anchor = AnchorStyles.Left | AnchorStyles.Right; controls[i].Margin = new Padding(i == 0 ? 0 : 8, 3, 0, 3); panel.Controls.Add(controls[i], i, 0); }
        return panel;
    }
    Button Button(string title, Func<Task> action, bool primary = false, bool tracked = true)
    {
        var button = new Button { Text = title, AutoSize = true, MinimumSize = new Size(78, 32), FlatStyle = FlatStyle.Flat, BackColor = primary ? Orange : Color.White, ForeColor = primary ? Color.White : Ink, Padding = new Padding(8, 2, 8, 2) };
        button.FlatAppearance.BorderColor = primary ? Orange : Color.LightGray;
        button.Click += async (_, _) => { if (tracked) await Guard(action); else { try { await action(); } catch (Exception e) { Notice(e.Message, true); } } };
        if (tracked) locked.Add(button);
        return button;
    }
    async Task Guard(Func<Task> action)
    {
        if (busy) return;
        busy = true; foreach (var control in locked) control.Enabled = false; progress.Value = 0;
        try { await action(); } catch (Exception e) { Notice(Errors.Friendly(e.Message), true); }
        finally { busy = false; installing = false; stop.Enabled = false; foreach (var control in locked) control.Enabled = true; UpdateInstall(); }
    }
    void Notice(string message, bool error = false) { status.Text = message; status.ForeColor = error ? Color.FromArgb(155, 62, 20) : Ink; Log(message); }
    void Log(string message) { if (message.Trim().Length == 0) return; logs.AppendText($"[{DateTime.Now:HH:mm:ss}] {message.Trim()}\r\n"); if (logs.TextLength > 200000) logs.Text = logs.Text[^150000..]; }
    void UpdateInstall() { install.Enabled = !busy && devices.SelectedItem is Device { Ready: true } && paths.Count > 0; }
    void LoadNetworks() { networks.Items.Clear(); networks.Items.AddRange(Lan.Current().Cast<object>().ToArray()); if (networks.Items.Count > 0) networks.SelectedIndex = 0; }
    async Task RefreshDevices()
    {
        var old = (devices.SelectedItem as Device)?.Serial;
        var found = await adb.Devices();
        devices.Items.Clear(); devices.Items.AddRange(found.Cast<object>().ToArray());
        int match = found.FindIndex(d => d.Serial == old);
        if (found.Count > 0) devices.SelectedIndex = match >= 0 ? match : Math.Max(0, found.FindIndex(d => d.Ready));
        Notice(found.Count == 0 ? "暂无已连接的设备。点击发现设备或输入 IP 连接。" : $"已列出 {found.Count} 台设备，请确认型号和地址。" );
    }
    async Task Discover()
    {
        if (networks.SelectedItem is not Lan lan) { LoadNetworks(); throw new IOException("请选择可用的局域网。"); }
        Notice("正在发现设备…");
        var uiProgress = new Progress<(int, int)>(p => progress.Value = p.Item2 == 0 ? 1000 : p.Item1 * 1000 / p.Item2);
        var found = await AdbClient.Scan(lan, (done, total) => ((IProgress<(int,int)>)uiProgress).Report((done,total)));
        var mdns = await adb.Run(["mdns", "services"]);
        found.AddRange(AdbClient.ParseServices(mdns.Output).Select(e => e.Address));
        foreach (var target in found.Distinct()) Log((await adb.Run(["connect", target], 8)).Output);
        await RefreshDevices();
        if (devices.Items.Count == 0) Notice("未发现网络 ADB。请手动输入 IP，或查看设备无线调试页面的端口。", true);
    }
    async Task Connect()
    {
        var target = Endpoint.Parse(address.Text);
        Log((await adb.Run(["connect", target.Address], 12)).Output);
        await RefreshDevices();
        var matches = devices.Items.Cast<Device>().ToArray(); int index = Array.FindIndex(matches, d => d.Serial == target.Address);
        if (index >= 0) { devices.SelectedIndex = index; Notice(matches[index].Ready ? $"已连接 {matches[index].Name}。" : "请在设备上允许调试后刷新状态。", !matches[index].Ready); }
        else Notice("未连接成功，请查看日志中的具体原因。", true);
    }
    async Task Pair()
    {
        using var dialog = new PairForm(); if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var pairing = Endpoint.Parse(dialog.PairAddress);
        var connection = Endpoint.Parse(dialog.ConnectionAddress);
        if (!dialog.PairAddress.Contains(':') || !dialog.ConnectionAddress.Contains(':') || !System.Text.RegularExpressions.Regex.IsMatch(dialog.Code, "^[0-9]{6}$")) throw new ArgumentException("请分别填写配对 IP:端口、连接 IP:端口和 6 位配对码。");
        var result = await adb.Run(["pair", pairing.Address], 25, dialog.Code);
        if (!result.Success || !result.Output.Contains("Successfully paired")) throw new IOException("配对失败，请确认配对窗口仍打开、端口正确，配对码未过期。");
        address.Text = connection.Address; await Connect();
    }
    async Task Disconnect() { if (devices.SelectedItem is Device device) { Log((await adb.Run(["disconnect", device.Serial])).Output); await RefreshDevices(); } }
    Task Choose() { using var dialog = new OpenFileDialog { Filter = "Android APK (*.apk)|*.apk", Multiselect = true, Title = "选择要安装的 APK" }; if (dialog.ShowDialog(this) == DialogResult.OK) AddFiles(dialog.FileNames); return Task.CompletedTask; }
    void AddFiles(string[] files)
    {
        foreach (var file in files)
        {
            string path = Path.GetFullPath(file); if (paths.Contains(path, StringComparer.OrdinalIgnoreCase)) continue;
            try { AdbClient.ValidateApk(path); paths.Add(path); queue.Rows.Add(Path.GetFileName(path), $"{new FileInfo(path).Length / 1048576.0:F1} MB", "待安装"); queue.Rows[queue.Rows.Count - 1].Cells[0].ToolTipText = path; }
            catch (Exception e) { Notice(e.Message, true); }
        }
        UpdateInstall();
    }
    Task Remove() { foreach (var i in queue.SelectedRows.Cast<DataGridViewRow>().Select(r => r.Index).OrderDescending()) { paths.RemoveAt(i); queue.Rows.RemoveAt(i); } return Task.CompletedTask; }
    Task Clear() { paths.Clear(); queue.Rows.Clear(); return Task.CompletedTask; }
    Task ClearInstalled() { installedRows.Rows.Clear(); return Task.CompletedTask; }
    Task StopQueue() { stopRemaining = true; stop.Enabled = false; return Task.CompletedTask; }
    async Task Install()
    {
        if (devices.SelectedItem is not Device { Ready: true } target || paths.Count == 0) return;
        installing = true; stopRemaining = false; stop.Enabled = true;
        var files = paths.ToArray(); var originalRows = files.Select((file, index) => (file, row: queue.Rows[index])).ToDictionary(x => x.file, x => x.row, StringComparer.OrdinalIgnoreCase); bool multiple = split.Checked;
        var groups = multiple ? new[] { files } : files.Select(f => new[] { f }).ToArray(); int success = 0, failure = 0;
        foreach (DataGridViewRow row in queue.Rows) { row.Cells[2].Value = "待安装"; row.DefaultCellStyle.ForeColor = Ink; }
        for (int i = 0; i < groups.Length; i++)
        {
            if (stopRemaining) break;
            Notice($"正在安装到 {target.Name} · {target.Serial}：{i + 1} / {groups.Length}");
            var rows = groups[i].Select(f => originalRows[f]).ToArray(); foreach (var row in rows) row.Cells[2].Value = "安装中";
            bool ok = false; string detail;
            try
            {
                var state = await adb.Run(["-s", target.Serial, "get-state"], 8);
                if (!state.Success || state.Output.Trim() != "device") throw new IOException(state.Output);
                var result = await adb.Run(AdbClient.InstallArguments(target.Serial, groups[i], multiple), 600);
                Log(result.Output); ok = result.Success && result.Output.Replace("\r", "").Split('\n').Any(l => l.Trim() == "Success");
                detail = ok ? "安装成功" : Errors.Friendly(result.Output);
            }
            catch (Exception e) { detail = Errors.Friendly(e.Message); Log(detail); }
            if (ok) {
                foreach (string file in groups[i]) {
                    var row = originalRows[file];
                    installedRows.Rows.Insert(0, Path.GetFileName(file), row.Cells[1].Value ?? "", $"{target.Name} · {target.Serial}", DateTime.Now.ToString("MM-dd HH:mm:ss"));
                    installedRows.Rows[0].Cells[0].ToolTipText = file;
                    paths.Remove(file); queue.Rows.Remove(row);
                }
            } else {
                foreach (var row in rows) { row.Cells[2].Value = "安装失败：" + detail; row.DefaultCellStyle.ForeColor = Color.Firebrick; }
            }
            if (ok) success++; else failure++; progress.Value = (i + 1) * 1000 / groups.Length;
        }
        if (stopRemaining) foreach (DataGridViewRow row in queue.Rows) if ((string?)row.Cells[2].Value == "待安装") row.Cells[2].Value = "已跳过";
        Notice($"{(stopRemaining ? "队列已停止" : "安装完成")}：成功 {success} 项，失败 {failure} 项。", failure > 0);
    }
    Task Export() { using var dialog = new SaveFileDialog { Filter = "文本日志|*.txt", FileName = "安卓设备安装日志.txt" }; if (dialog.ShowDialog(this) == DialogResult.OK) File.WriteAllText(dialog.FileName, logs.Text, Encoding.UTF8); return Task.CompletedTask; }
    Task Preparation() { using var guide = new PreparationForm(); guide.ShowDialog(this); return Task.CompletedTask; }
    Task Help() { MessageBox.Show("1. 设备设置中开启网络 ADB 或无线调试，与电脑接入同一局域网。\n2. 发现设备或输入 IP:端口，设备弹出授权时选择允许。\n3. 选择目标设备，拖入 APK 后开始安装。\n\n拆分 APK 必须选齐同一应用的 base 与 split 文件。XAPK/APKM/AAB 不能直接安装。\n无线配对使用设备显示的配对端口与连接端口，两者通常不同。\n\n本工具不能远程开启被固件关闭的网络 ADB 服务。断开连接不会关闭设备调试服务。", "使用帮助"); return Task.CompletedTask; }
}

class PairForm : Form
{
    readonly TextBox pairing = new(), connection = new(), code = new() { UseSystemPasswordChar = true, MaxLength = 6 };
    public string PairAddress => pairing.Text.Trim(); public string ConnectionAddress => connection.Text.Trim(); public string Code => code.Text.Trim();
    public PairForm()
    {
        Text = "无线调试配对"; Size = new Size(520, 330); FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; StartPosition = FormStartPosition.CenterParent;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), RowCount = 7, ColumnCount = 1 };
        layout.Controls.Add(new Label { Text = "打开设备「无线调试 → 使用配对码配对」，保持窗口打开。", AutoSize = true });
        foreach (var (title, field) in new[] { ("配对 IP:端口", pairing), ("6 位配对码", code), ("连接 IP:端口（无线调试主页面）", connection) })
        {
            var row = new TableLayoutPanel { Dock = DockStyle.Top, Height = 48, ColumnCount = 2 }; row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 220)); row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            row.Controls.Add(new Label { Text = title, AutoSize = true, Anchor = AnchorStyles.Left }); field.Dock = DockStyle.Fill; row.Controls.Add(field); layout.Controls.Add(row);
        }
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
        var ok = new Button { Text = "配对并连接", DialogResult = DialogResult.OK, AutoSize = true }; buttons.Controls.Add(ok); buttons.Controls.Add(new Button { Text = "取消", DialogResult = DialogResult.Cancel }); layout.Controls.Add(buttons); Controls.Add(layout); AcceptButton = ok;
    }
}
