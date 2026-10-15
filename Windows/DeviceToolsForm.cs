namespace TVAppInstaller;
public class DeviceToolsForm : Form
{
    readonly AdbClient adb; readonly Device target;
    readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    readonly ListView apps = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false };
    readonly TextBox search = new() { PlaceholderText = "搜索应用包名", Width = 260 };
    readonly CheckBox system = new() { Text = "包含系统应用", AutoSize = true };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 62, Padding = new Padding(12), AutoEllipsis = true };
    readonly PictureBox preview = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.FromArgb(245,245,240) };
    readonly List<(string Package, bool System)> packages = [];
    readonly List<Control> controls = []; readonly Button open, stop, clear, uninstall, save;
    byte[]? screenshot; bool busy;
    public DeviceToolsForm(AdbClient client, Device device)
    {
        adb = client; target = device; Text = "设备工具 · " + device.Name; Size = new Size(860, 650); MinimumSize = new Size(760, 580); StartPosition = FormStartPosition.CenterParent; Font = new Font("Microsoft YaHei UI", 10);
        var title = new Label { Text = device.Name + " · " + device.Serial, Dock = DockStyle.Top, Height = 46, Padding = new Padding(14), BackColor = Color.WhiteSmoke };
        Controls.Add(tabs); Controls.Add(title); Controls.Add(status);
        var page = new TabPage("设备应用"); tabs.TabPages.Add(page);
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 48, Padding = new Padding(8) };
        top.Controls.AddRange([search, system, Make("刷新", RefreshApps)]); controls.Add(system);
        apps.Columns.Add("应用包名", 580); apps.Columns.Add("类型", 100);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 50, Padding = new Padding(8) };
        open = Make("打开", Launch); stop = Make("强制停止", () => Action("强制停止")); clear = Make("清除数据", () => Action("清除数据")); uninstall = Make("卸载", () => Action("卸载")); actions.Controls.AddRange([open,stop,clear,uninstall]);
        page.Controls.Add(apps); page.Controls.Add(top); page.Controls.Add(actions);
        search.TextChanged += (_,_) => Render(); system.CheckedChanged += async (_,_) => await Run(RefreshApps); apps.SelectedIndexChanged += (_,_) => Selection();
        var remote = new TabPage("虚拟遥控器"); tabs.TabPages.Add(remote);
        var pad = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 6, Padding = new Padding(90,25,90,25) };
        for(int i=0;i<3;i++) pad.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.33f));
        for(int i=0;i<6;i++) pad.RowStyles.Add(new RowStyle(SizeType.Percent,16.66f));
        var positions = new[] { (1,0),(0,1),(1,1),(2,1),(1,2),(0,3),(2,3),(0,4),(2,4) };
        for(int i=0;i<DeviceCommands.Keys.Length;i++) { var key = DeviceCommands.Keys[i]; pad.Controls.Add(Make(key.Name,async()=> { await Shell(DeviceCommands.Key(key.Code)); Note("按键已发送。若无响应，请检查设备的模拟输入权限。"); }),positions[i].Item1,positions[i].Item2); }
        pad.Controls.Add(new Label { Text="控制所选设备。部分设备需额外允许模拟输入。",AutoSize=true },0,5); pad.SetColumnSpan(pad.GetControlFromPosition(0,5)!,3); remote.Controls.Add(pad);
        var screen = new TabPage("截图"); tabs.TabPages.Add(screen);
        var toolbar = new FlowLayoutPanel { Dock=DockStyle.Top,Height=52,Padding=new Padding(8) };
        save=Make("保存截图…",Save);toolbar.Controls.AddRange([Make("截取画面",CaptureScreen),save]);screen.Controls.Add(preview);screen.Controls.Add(toolbar);
        Note("点击刷新读取当前用户的应用，按包名显示。受保护的画面可能无法截取。"); Selection();
        FormClosing += (_,e)=> { if(busy)e.Cancel=true; }; FormClosed += (_,_)=>preview.Image?.Dispose();
    }
    Button Make(string name, Func<Task> work) { var button=new Button {Text=name,AutoSize=true,MinimumSize=new Size(84,34),Dock=DockStyle.Fill};button.Click+=async(_,_)=>await Run(work);controls.Add(button);return button; }
    async Task Run(Func<Task> work) {if(busy)return;busy=true;foreach(var c in controls)c.Enabled=false;apps.Enabled=false;try{await work();}catch(Exception e){Note(Errors.Friendly(e.Message),true);}finally{busy=false;foreach(var c in controls)c.Enabled=true;apps.Enabled=true;Selection();}}
    void Note(string text,bool error=false){status.Text=text;status.ForeColor=error?Color.Firebrick:Color.DimGray;}
    Task<string> Shell(string command)=>DeviceCommands.Shell(adb,target.Serial,command);
    (string Package,bool System)? Chosen => apps.SelectedItems.Count==0?null:((string Package,bool System))apps.SelectedItems[0].Tag!;
    void Selection(){open.Enabled=stop.Enabled=!busy&&Chosen!=null;clear.Enabled=uninstall.Enabled=!busy&&Chosen is {System:false};save.Enabled=!busy&&screenshot!=null;}
    void Render(){var selected=Chosen?.Package;apps.Items.Clear();foreach(var item in packages.Where(x=>x.Package.Contains(search.Text,StringComparison.OrdinalIgnoreCase))){var row=new ListViewItem([item.Package,item.System?"系统应用":"用户应用"]){Tag=item};apps.Items.Add(row);if(item.Package==selected)row.Selected=true;}Selection();}
    async Task RefreshApps(){Note("正在读取设备应用…");var third=DeviceCommands.Packages(await Shell("pm list packages -3 --user current")).ToHashSet();var all=system.Checked?DeviceCommands.Packages(await Shell("pm list packages --user current")):third.Order().ToArray();packages.Clear();packages.AddRange(all.Select(x=>(x,!third.Contains(x))));Render();Note($"已读取 {packages.Count} 个应用 · 当前用户。");}
    async Task Launch(){if(Chosen is not {} app)return;string pkg=DeviceCommands.Package(app.Package);foreach(string category in new[]{"LEANBACK_LAUNCHER","LAUNCHER"}){string? component=DeviceCommands.Component(await Shell("cmd package resolve-activity --brief --user current -a android.intent.action.MAIN -c android.intent.category."+category+" "+pkg));if(component!=null&&component.StartsWith(pkg+"/",StringComparison.Ordinal)){await Shell("am start --user current -n '"+component+"'");Note("应用已打开。");return;}}throw new IOException("此应用没有可打开的电视或手机桌面入口。");}
    async Task Action(string kind){if(Chosen is not {} app)return;if(app.System&&kind!="强制停止")return;if(kind!="强制停止"&&MessageBox.Show($"目标：{target.Name} · {target.Serial}\n应用：{app.Package}\n\n"+(kind=="卸载"?"卸载会删除应用及其数据。":"会删除登录状态、设置和本地数据，不只是清缓存。"),"确认"+kind,MessageBoxButtons.OKCancel,MessageBoxIcon.Warning)!=DialogResult.OK)return;string command=kind=="卸载"?"pm uninstall --user current ":kind=="清除数据"?"pm clear --user current ":"am force-stop --user current ";string output=await Shell(command+DeviceCommands.Package(app.Package));if(kind!="强制停止"&&output!="Success")throw new IOException(output.Length==0?"设备未确认操作成功。":output);if(kind=="卸载"){packages.RemoveAll(x=>x.Package==app.Package);Render();}Note(kind+"完成。");}
    async Task CaptureScreen(){Note("正在截取画面…");var data=await DeviceCommands.Screenshot(adb,target.Serial);using var stream=new MemoryStream(data);using var decoded=Image.FromStream(stream);var image=new Bitmap(decoded);preview.Image?.Dispose();preview.Image=image;screenshot=data;Note("截图完成，可以保存到电脑。");}
    Task Save(){if(screenshot==null)return Task.CompletedTask;using var dialog=new SaveFileDialog{Filter="PNG 图片|*.png",FileName="设备截图.png"};if(dialog.ShowDialog(this)==DialogResult.OK){File.WriteAllBytes(dialog.FileName,screenshot);Note("截图已保存。");}return Task.CompletedTask;}
}
