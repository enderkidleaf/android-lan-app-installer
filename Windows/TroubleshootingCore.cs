using System.Text.RegularExpressions;
namespace TVAppInstaller;
public record DiagnosisReport(bool Connected, bool RestartAllowed, string Summary);
public static class TerminalCodec
{
    public static string Validate(string command) => !string.IsNullOrWhiteSpace(command) && System.Text.Encoding.UTF8.GetByteCount(command) <= 8192 && !command.Contains('\0') ? command : throw new IOException("请输入一条命令，最多 8192 字节，不能包含空字符。");
    public static string Wrap(string command, string marker) => "(\n" + Validate(command) + "\n); result=$?; printf '\\n" + marker + ":%s\\n' \"$result\"";
    public static (string Text, int? Code) Parse(string output, string marker) { int index = output.LastIndexOf("\n" + marker + ":", StringComparison.Ordinal); return index >= 0 && int.TryParse(output[(index + marker.Length + 2)..].Trim(), out int code) ? (output[..index], code) : (output, null); }
}
public class ConnectionDoctor(Func<string[], int, Task<CommandResult>> run, Func<Endpoint, Task<bool>> probe, Action<string> emit)
{
    public static List<(string Serial, string State)>? Occupants(CommandResult result)
    {
        int header = result.Output.IndexOf("List of devices attached", StringComparison.Ordinal);
        if (!result.Success || header < 0) return null;
        return result.Output[(header + "List of devices attached".Length)..].Split('\n').Select(x=>Regex.Split(x.Trim(),@"\s+")).Where(x=>x.Length>0&&x[0].Length>0).Select(x=>(x[0],x.Length>1?x[1]:"unknown")).ToList();
    }
    async Task<CommandResult> Command(string[] args,int seconds=8) { emit("$ adb "+string.Join(' ',args));var result=await run(args,seconds);emit(result.Output.Length==0?"（无输出）":result.Output);if(result.Cancelled)throw new IOException("操作已停止。");return result; }
    async Task<DiagnosisReport> Check(Endpoint endpoint)
    {
        emit("目标："+endpoint.Address);bool open=await probe(endpoint);emit(open?"TCP 端口可访问。":"TCP 端口不可访问：检查电源、地址、端口、网络调试与本机局域网权限。");
        var initial=Occupants(await Command(["devices","-l"]));var connection=await Command(["connect",endpoint.Address],12);var latest=Occupants(await Command(["devices","-l"]));
        if(latest==null)return new(false,false,"无法可靠读取 ADB 状态，已禁止重启服务。请查看原始输出。");
        if(latest.Any(x=>x.Serial==endpoint.Address&&x.State=="unauthorized")||connection.Output.Contains("unauthorized",StringComparison.OrdinalIgnoreCase)||connection.Output.Contains("authenticate"))return new(false,false,"等待设备授权：请在设备上允许调试，然后重新检查。");
        if(latest.Any(x=>x.Serial==endpoint.Address&&x.State=="device")){var shell=await Command(["-s",endpoint.Address,"shell","echo ADB_DIAG_OK"]);if(shell.Success&&shell.Output.Trim()=="ADB_DIAG_OK")return new(true,false,open?"连接正常，授权和设备命令通道均可用，无需重启服务。":"ADB 命令通道正常，但应用端口探测受阻，可能与本机权限或网络策略有关。可继续使用 ADB，无需重启服务。");}
        if(latest.Any(x=>x.Serial!=endpoint.Address))return new(false,false,"存在其他 ADB 设备（包括 USB / 模拟器），不会重启共享服务。请处理目标设备的连接。");
        if(!open)return new(false,false,"目标端口不可访问，重启 ADB 不能解决网络或设备端口问题。请确认网络调试与正确端口。");
        if(initial==null)return new(false,false,"最初的 ADB 状态无法确认，暂不重启共享服务。");
        return new(false,true,"端口可访问，但 ADB 命令通道失败，可能是后台服务或设备连接异常。可点击修复连接。");
    }
    public async Task<DiagnosisReport> Diagnose(string address,bool repair)
    {
        var endpoint=Endpoint.Parse(address);var report=await Check(endpoint);
        if(!repair||report.Connected||!report.RestartAllowed)return report;
        var devices=Occupants(await Command(["devices","-l"]));
        if(devices==null||devices.Any(x=>x.Serial!=endpoint.Address||x.State=="unauthorized"))return new(false,false,"设备状态已变化，已取消服务重启。请重新检查。");
        emit("未发现其他设备，开始重启本机 ADB 服务。不更改设备设置或清除授权密钥。");
        if(!(await Command(["kill-server"])).Success)return new(false,false,"停止服务失败，请查看输出；未继续重启。");
        if(!(await Command(["start-server"])).Success)return new(false,false,"启动 ADB 服务失败，请查看输出。");
        var verified=await Check(endpoint);return new(verified.Connected,false,verified.Connected?verified.Summary:"服务已重启，但连接仍未恢复。"+verified.Summary);
    }
    public static Task<bool> Probe(Endpoint endpoint) => Probe(endpoint, _=>{});
    public static async Task<bool> Probe(Endpoint endpoint,Action<string> report)
    {
        using var client=new System.Net.Sockets.TcpClient();using var timeout=new CancellationTokenSource(1800);
        try { await client.ConnectAsync(endpoint.Host,endpoint.Port,timeout.Token); return true; }
        catch(System.Net.Sockets.SocketException e) {
            report(e.SocketErrorCode switch {
                System.Net.Sockets.SocketError.ConnectionRefused=>"端口拒绝连接：请检查网络 ADB 开关和正确端口。",
                System.Net.Sockets.SocketError.HostUnreachable or System.Net.Sockets.SocketError.NetworkUnreachable=>"网络无法到达目标设备：请检查局域网和目标 IP。",
                System.Net.Sockets.SocketError.AccessDenied=>"本机拒绝网络访问：请检查防火墙和应用网络权限。",
                _=>"端口检查失败："+e.Message }); return false;
        }
        catch(OperationCanceledException) { report("连接端口超时：请检查设备电源、IP 与网络隔离。"); return false; }
    }
}
