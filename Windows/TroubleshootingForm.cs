using System.Text;
namespace TVAppInstaller;
public class TroubleshootingForm : Form
{
    readonly AdbClient adb;
    readonly TextBox target=new(){Dock=DockStyle.Top,PlaceholderText="目标 IP:端口，例如 192.168.1.73:5555"};
    readonly TextBox command=new(){Dock=DockStyle.Top,Text="getprop ro.product.model"};
    readonly TextBox output=new(){Multiline=true,ReadOnly=true,Dock=DockStyle.Fill,ScrollBars=ScrollBars.Both,WordWrap=false,Font=new Font("Consolas",10)};
    readonly Label status=new(){Dock=DockStyle.Bottom,Height=58,Padding=new Padding(8),AutoEllipsis=true};
    readonly List<Control> locked=[];readonly Button stop;CancellationTokenSource? running;bool busy;
    public TroubleshootingForm(AdbClient client,string address,string initialOutput)
    {
        adb=client;Text="连接诊断与 ADB 终端";Size=new Size(1000,740);MinimumSize=new Size(850,650);StartPosition=FormStartPosition.CenterParent;Font=new Font("Microsoft YaHei UI",10);Padding=new Padding(18);
        target.Text=address;output.Text=initialOutput;locked.AddRange([target,command]);
        var tabs=new TabControl{Dock=DockStyle.Top,Height=164};
        var diagnosis=new TabPage("连接诊断与修复");tabs.TabPages.Add(diagnosis);
        var diag=new FlowLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(10)};
        diag.Controls.Add(new Label{Text="检查端口、设备授权和命令通道。检测到其他 ADB 设备时，不会重启共享服务。",AutoSize=true});diag.SetFlowBreak(diag.Controls[0],true);
        diag.Controls.Add(Make("检查连接",()=>Diagnose(false)));diag.Controls.Add(Make("修复连接",()=>Diagnose(true)));diagnosis.Controls.Add(diag);
        var terminal=new TabPage("ADB 终端");tabs.TabPages.Add(terminal);
        var quick=new FlowLayoutPanel{Dock=DockStyle.Top,Height=43};
        foreach(var item in new[]{("设备型号","getprop ro.product.model"),("存储空间","df -h /data"),("最近系统日志","logcat -d -t 200")}){var button=Make(item.Item1,()=>{command.Text=item.Item2;return Task.CompletedTask;});quick.Controls.Add(button);}
        quick.Controls.Add(Make("本机设备列表",()=>Terminal(["devices","-l"])));quick.Controls.Add(Make("后台服务状态",()=>Terminal(["server-status"])));quick.Controls.Add(Make("运行",()=>Terminal()));
        var hint=new Label{Text="命令在目标设备执行，一次一条，不支持交互；自定义命令可能改动设备数据。",Dock=DockStyle.Top,Height=28};terminal.Controls.Add(command);terminal.Controls.Add(quick);terminal.Controls.Add(hint);
        var bottom=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=45};
        var copy=new Button{Text="复制输出",AutoSize=true};copy.Click+=(_,_)=>{if(output.TextLength>0)Clipboard.SetText(output.Text);};bottom.Controls.Add(copy);
        var export=new Button{Text="导出…",AutoSize=true};export.Click+=(_,_)=>{using var dialog=new SaveFileDialog{Filter="文本日志|*.txt",FileName="ADB排障记录.txt"};if(dialog.ShowDialog(this)==DialogResult.OK)File.WriteAllText(dialog.FileName,output.Text,Encoding.UTF8);};bottom.Controls.Add(export);
        bottom.Controls.Add(Make("清空",()=>{output.Clear();return Task.CompletedTask;}));stop=new Button{Text="停止",AutoSize=true,Enabled=false};stop.Click+=(_,_)=>running?.Cancel();bottom.Controls.Add(stop);
        Controls.Add(output);Controls.Add(tabs);Controls.Add(target);Controls.Add(status);Controls.Add(bottom);status.Text="输入目标 IP:端口，检查连接或查看终端。";
        FormClosing+=(_,e)=>{if(busy){e.Cancel=true;running?.Cancel();status.Text="正在停止当前操作，完成后可关闭。";}};
    }
    Button Make(string title,Func<Task> work){var button=new Button{Text=title,AutoSize=true,MinimumSize=new Size(82,32)};button.Click+=async(_,_)=>await Run(work);locked.Add(button);return button;}
    async Task Run(Func<Task> work){if(busy)return;busy=true;running=new CancellationTokenSource();foreach(var view in locked)view.Enabled=false;stop.Enabled=true;try{await work();}catch(Exception e){status.Text=Errors.Friendly(e.Message);Append(status.Text);}finally{busy=false;stop.Enabled=false;foreach(var view in locked)view.Enabled=true;running.Dispose();running=null;}}
    void Append(string text){output.AppendText(text.Replace("\r\n","\n").Replace("\n","\r\n")+"\r\n");if(output.TextLength>256*1024)output.Text=output.Text[^120000..];output.SelectionStart=output.TextLength;output.ScrollToCaret();}
    async Task Diagnose(bool repair){Append($"\n[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] "+(repair?"检查并修复连接":"检查连接"));status.Text="正在检查…";var doctor=new ConnectionDoctor((args,seconds)=>adb.ConsoleRun(args,seconds,running!.Token),endpoint=>ConnectionDoctor.Probe(endpoint,Append),Append);var report=await doctor.Diagnose(target.Text,repair);status.Text=report.Summary;Append(report.Summary);}
    async Task Terminal(string[]? host=null)
    {
        string serial=target.Text.Trim(),marker="__ADB_TERM_"+Guid.NewGuid().ToString("N");string[] args;
        if(host!=null){if(!new[]{"devices -l","server-status"}.Contains(string.Join(' ',host)))throw new IOException("不支持的本机诊断命令。");args=host;}
        else{if(!serial.StartsWith("adb-",StringComparison.Ordinal))serial=Endpoint.Parse(serial).Address;args=["-s",serial,"shell",TerminalCodec.Wrap(command.Text,marker)];}
        Append($"\n[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] "+(host==null?serial+" $ "+command.Text:"本机 adb "+string.Join(' ',host)));string prefix=output.Text;var token=running!.Token;var progress=new Progress<string>(text=>{if(busy&&running?.Token==token){output.Text=prefix+(host==null?TerminalCodec.Parse(text,marker).Text:text);output.SelectionStart=output.TextLength;output.ScrollToCaret();}});
        status.Text="正在执行，可点击停止。";var result=await adb.ConsoleRun(args,60,token,text=>((IProgress<string>)progress).Report(text));var parsed=host==null?TerminalCodec.Parse(result.Output,marker):(result.Output,(int?)result.Code);output.Text=prefix+parsed.Item1;
        status.Text=result.Cancelled?"已停止当前命令。":result.OutputLimited?"输出达到 256 KB，已停止当前命令。":result.TimedOut?"命令超过 60 秒，已停止当前命令。":"命令结束，退出码："+(parsed.Item2?.ToString()??"未返回");Append("\n["+status.Text+"]");
    }
}
