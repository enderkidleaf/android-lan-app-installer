using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace TVAppInstaller;

public record Endpoint(string Host, int Port)
{
    public string Address => $"{Host}:{Port}";
    public static Endpoint Parse(string input)
    {
        var parts = input.Trim().Split(':');
        if (parts.Length is < 1 or > 2 || !Regex.IsMatch(parts[0], @"^[0-9]{1,3}(\.[0-9]{1,3}){3}$"))
            throw new ArgumentException("请输入设备 IPv4 地址，例如 192.168.1.100:5555。");
        var octets = parts[0].Split('.').Select(int.Parse).ToArray();
        if (octets.Any(x => x > 255) || octets[0] is 0 or 127 or >= 224)
            throw new ArgumentException("请输入有效的设备局域网 IP。");
        int port = 5555;
        if (parts.Length == 2 && (!int.TryParse(parts[1], out port) || port is < 1 or > 65535))
            throw new ArgumentException("端口应在 1 到 65535 之间。");
        return new Endpoint(string.Join('.', octets), port);
    }
}

public record Device(string Serial, string State, string Model, string Android = "", string Architecture = "")
{
    public bool Ready => State == "device";
    public string Name => string.IsNullOrEmpty(Model) ? "Android 设备" : Model.Replace('_', ' ');
    public string Status => State switch { "device" => "已连接", "unauthorized" => "等待设备授权", "offline" => "设备离线", _ => State };
    public override string ToString() => $"{Name} · {Serial} · {Status}" + (Android.Length > 0 ? $" · Android {Android}" : "");
}

public record Lan(string Name, string Ip, uint Mask)
{
    public override string ToString() => $"{Name} · {Ip}/{System.Numerics.BitOperations.PopCount(Mask)}";
    public static uint Number(string ip) => ip.Split('.').Select(uint.Parse).Aggregate(0U, (n, x) => (n << 8) | x);
    public static string Text(uint ip) => string.Join('.', new[] { 24, 16, 8, 0 }.Select(x => (ip >> x) & 255));
    public string[] Hosts()
    {
        uint own = Number(Ip), mask = Math.Max(Mask, 0xffffff00U), first = own & mask, last = first | ~mask;
        if ((ulong)last <= (ulong)first + 1) return [];
        return Enumerable.Range(1, (int)(last - first - 1)).Select(x => first + (uint)x).Where(x => x != own).Select(Text).ToArray();
    }
    public static List<Lan> Current() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType is not NetworkInterfaceType.Loopback and not NetworkInterfaceType.Tunnel)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !a.Address.ToString().StartsWith("169.254."))
            .Select(a => new Lan(n.Name, a.Address.ToString(), Number(a.IPv4Mask.ToString())))).ToList();
}

public record CommandResult(int Code, string Output, bool TimedOut = false, bool Cancelled = false, bool OutputLimited = false) { public bool Success => Code == 0 && !TimedOut && !Cancelled && !OutputLimited; }

public class AdbClient(string executable)
{
    public async Task<CommandResult> ConsoleRun(string[] args, int seconds, CancellationToken stop, Action<string>? output = null, int limit = 256 * 1024)
    {
        if (stop.IsCancellationRequested) return new(-1, "", Cancelled: true);
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8 };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        using var process = new Process { StartInfo = start };
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(stop, timeout.Token);
        var buffer = new System.Text.StringBuilder(); object gate = new(); int bytes = 0; bool limited = false;
        process.Start(); process.StandardInput.Close();
        async Task Read(StreamReader reader)
        {
            char[] chars = new char[2048];
            try {
                int count;
                while ((count = await reader.ReadAsync(chars.AsMemory(), linked.Token)) > 0) {
                    lock (gate) {
                        string value = new(chars, 0, count); int size = System.Text.Encoding.UTF8.GetByteCount(value);
                        if (bytes + size > limit) {
                            int keep = Math.Min(value.Length, Math.Max(0, limit - bytes));
                            while (keep > 0 && System.Text.Encoding.UTF8.GetByteCount(value.AsSpan(0, keep)) > limit - bytes) keep--;
                            value = value[..keep]; limited = true;
                        }
                        buffer.Append(value); bytes += System.Text.Encoding.UTF8.GetByteCount(value); output?.Invoke(buffer.ToString());
                        if (limited) linked.Cancel();
                    }
                    if (limited) break;
                }
            } catch (OperationCanceledException) { }
        }
        var stdout = Read(process.StandardOutput); var stderr = Read(process.StandardError);
        try { await process.WaitForExitAsync(linked.Token); }
        catch (OperationCanceledException) { if (!process.HasExited) process.Kill(); await process.WaitForExitAsync(); }
        await Task.WhenAll(stdout, stderr);
        return new(process.ExitCode, buffer.ToString(), timeout.IsCancellationRequested && !stop.IsCancellationRequested && !limited, stop.IsCancellationRequested, limited);
    }
    public async Task<CommandResult> Run(string[] args, int seconds = 15, string? input = null)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8 };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        using var process = new Process { StartInfo = start };
        process.Start();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (input != null) await process.StandardInput.WriteLineAsync(input);
        process.StandardInput.Close();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        bool timedOut = false;
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            timedOut = true;
            // Kill this command only. Leave the shared ADB server and other devices alone.
            if (!process.HasExited) process.Kill();
            await process.WaitForExitAsync();
        }
        return new CommandResult(process.ExitCode, await stdout + await stderr + (timedOut ? "\n操作超时 (timed out)" : ""), timedOut);
    }

    public async Task<List<Device>> Devices()
    {
        var result = await Run(["devices", "-l"]);
        if (!result.Success) throw new IOException(Errors.Friendly(result.Output));
        var devices = ParseDevices(result.Output);
        for (int i = 0; i < devices.Count; i++)
        {
            var device = devices[i];
            if (!device.Ready) continue;
            var properties = await Run(["-s", device.Serial, "shell", "getprop ro.product.model; getprop ro.build.version.release; getprop ro.product.cpu.abilist"], 6);
            var values = properties.Output.Replace("\r", "").Split('\n');
            if (properties.Success && values.Length >= 3) devices[i] = device with { Model = values[0].Trim(), Android = values[1].Trim(), Architecture = values[2].Trim() };
        }
        return devices;
    }
    public static List<Device> ParseDevices(string output) => output.Split('\n').Select(line => Regex.Split(line.Trim(), @"\s+"))
        .Where(p => p.Length >= 2 && (p[0].Contains(':') || p[0].StartsWith("adb-")) && new[] { "device", "offline", "unauthorized" }.Contains(p[1]))
        .Select(p => new Device(p[0], p[1], p.FirstOrDefault(x => x.StartsWith("model:"))?[6..] ?? "")).ToList();
    public static List<Endpoint> ParseServices(string output) => output.Split('\n').Where(l => l.Contains("_adb-tls-connect._tcp"))
        .Select(l => Regex.Split(l.Trim(), @"\s+").Last()).Select(s => { try { return Endpoint.Parse(s); } catch { return null; } })
        .OfType<Endpoint>().Distinct().ToList();
    public static void ValidateApk(string path)
    {
        if (!path.EndsWith(".apk", StringComparison.OrdinalIgnoreCase)) throw new IOException("请选择 .apk 文件；XAPK、APKM、AAB 不能直接安装。");
        using var input = File.OpenRead(path);
        byte[] header = new byte[4];
        if (input.Read(header) != 4 || !header.SequenceEqual(new byte[] { 0x50, 0x4b, 3, 4 })) throw new IOException($"{Path.GetFileName(path)} 不是有效的 APK / ZIP 文件。");
    }
    public static string[] InstallArguments(string serial, string[] paths, bool split)
    {
        if (string.IsNullOrEmpty(serial) || paths.Length == 0) throw new ArgumentException("请先选择设备和 APK。");
        foreach (var path in paths) ValidateApk(path);
        return ["-s", serial, split ? "install-multiple" : "install", "-r", .. paths];
    }
    public static async Task<List<string>> Scan(Lan lan, Action<int, int> progress)
    {
        var hosts = lan.Hosts();
        var found = new System.Collections.Concurrent.ConcurrentBag<string>();
        int count = 0;
        await Parallel.ForEachAsync(hosts, new ParallelOptions { MaxDegreeOfParallelism = 24 }, async (host, _) =>
        {
            using var client = new TcpClient();
            using var timeout = new CancellationTokenSource(700);
            try { await client.ConnectAsync(host, 5555, timeout.Token); found.Add($"{host}:5555"); } catch (SocketException) { } catch (OperationCanceledException) { }
            progress(Interlocked.Increment(ref count), hosts.Length);
        });
        return found.Order().ToList();
    }
}

public static class Errors
{
    public static string Friendly(string output)
    {
        string[] codes = ["UPDATE_INCOMPATIBLE", "VERSION_DOWNGRADE", "NO_MATCHING_ABIS", "OLDER_SDK", "INSUFFICIENT_STORAGE", "USER_RESTRICTED", "MISSING_SPLIT"];
        string[] messages = ["签名与已安装版本不同，请使用同一来源的 APK。", "版本低于设备上的已安装版本，请选择更新的 APK。", "处理器架构不兼容，请选择与设备处理器架构匹配的版本。", "APK 要求更高的 Android 版本。", "设备存储空间不足，请先清理空间。", "设备限制安装，请检查未知来源设置并确认设备提示。", "缺少拆分文件，请选齐同一应用的 base 和 split APK，并勾选拆分模式。"];
        for (int i = 0; i < codes.Length; i++) if (output.Contains("INSTALL_FAILED_" + codes[i])) return messages[i];
        if (output.Contains("unauthorized", StringComparison.OrdinalIgnoreCase) || output.Contains("authenticate")) return "请在设备的调试授权弹窗选择「允许」，再刷新状态。";
        if (output.Contains("refused", StringComparison.OrdinalIgnoreCase)) return "设备未开放此端口，请检查 ADB 开关或无线调试的连接端口。";
        if (output.Contains("timed out", StringComparison.OrdinalIgnoreCase) || output.Contains("10060") || output.Contains("10065")) return "连接超时，请确认设备已开机、IP 正确、同一局域网没有客户端隔离。";
        if (output.Contains("offline") || output.Contains("not found")) return "设备离线，请重新连接设备。";
        return output.Trim();
    }
}
