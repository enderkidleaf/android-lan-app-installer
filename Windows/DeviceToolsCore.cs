using System.Text.RegularExpressions;
namespace TVAppInstaller;
public static class DeviceCommands
{
    public static string Package(string value) => Regex.IsMatch(value, @"\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z") ? value : throw new IOException("设备返回了无效的应用包名。");
    public static string[] Packages(string output) => output.Split('\n').Select(x => x.Trim()).Where(x => x.StartsWith("package:")).Select(x => x[8..]).Where(x => Regex.IsMatch(x, @"\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z")).Distinct().Order().ToArray();
    public static string? Component(string output) => output.Split('\n').Select(x => x.Trim()).FirstOrDefault(x => Regex.IsMatch(x, @"\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+\z"));
    public static readonly (string Name, string Code)[] Keys = [("上", "KEYCODE_DPAD_UP"), ("左", "KEYCODE_DPAD_LEFT"), ("确认", "KEYCODE_DPAD_CENTER"), ("右", "KEYCODE_DPAD_RIGHT"), ("下", "KEYCODE_DPAD_DOWN"), ("返回", "KEYCODE_BACK"), ("主页", "KEYCODE_HOME"), ("音量 −", "KEYCODE_VOLUME_DOWN"), ("音量 +", "KEYCODE_VOLUME_UP")];
    public static string Key(string value) => Keys.Any(x => x.Code == value) ? "input keyevent " + value : throw new IOException("不支持的遥控按键。");
    public static string Wrapped(string command) => command + "; result=$?; printf '\\n__TOOLS_EXIT:%s\\n' \"$result\"";
    public static string Checked(string output)
    {
        int index = output.LastIndexOf("\n__TOOLS_EXIT:", StringComparison.Ordinal);
        if (index < 0 || output[(index + 14)..].Trim() != "0") throw new IOException(output.Trim().Length == 0 ? "设备没有确认操作成功。" : output.Trim());
        string text = output[..index].Trim();
        if (text.Split('\n').Any(x => x.StartsWith("Error:") || x.StartsWith("Exception") || x.StartsWith("Failure"))) throw new IOException(text);
        return text;
    }
    public static bool ValidPng(byte[] data) => data.Length > 24 && data.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
    public static async Task<string> Shell(AdbClient client, string serial, string command)
    {
        var result = await client.Run(["-s", serial, "shell", Wrapped(command)], 30);
        if (!result.Success) throw new IOException(Errors.Friendly(result.Output));
        return Checked(result.Output);
    }
    public static async Task<byte[]> Screenshot(AdbClient client, string serial)
    {
        string remote = "/data/local/tmp/android-lan-screen-" + Guid.NewGuid().ToString("N") + ".png", local = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".png");
        try
        {
            await Shell(client, serial, "screencap -p " + remote);
            var result = await client.Run(["-s", serial, "pull", remote, local], 30);
            if (!result.Success) throw new IOException(Errors.Friendly(result.Output));
            if (new FileInfo(local).Length > 32 * 1024 * 1024) throw new IOException("截图超过 32 MB。");
            byte[] data = await File.ReadAllBytesAsync(local);
            if (!ValidPng(data)) throw new IOException("设备没有返回有效截图，可能不支持截屏。");
            return data;
        }
        finally { try { await Shell(client, serial, "rm -f " + remote); } catch { } try { File.Delete(local); } catch { } }
    }
}
