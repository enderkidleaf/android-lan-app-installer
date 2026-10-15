using TVAppInstaller;
using System.Text;

int checks = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
void Reject(Action action) { try { action(); } catch { checks++; return; } throw new Exception("Expected rejection"); }
Check(Endpoint.Parse(" 192.168.1.100 ").Address == "192.168.1.100:5555", "default endpoint");
Check(Endpoint.Parse("192.168.1.100:39000").Port == 39000, "custom port");
foreach (var value in new[] { "", "192.168.1.999", "192.168.1", "127.0.0.1", "0.0.0.0", "224.0.0.1", "192.168.1.1:0", "192.168.1.1:65536", "192.168.1.1;echo hi" }) Reject(() => Endpoint.Parse(value));
var devices = AdbClient.ParseDevices("List of devices attached\n192.168.1.100:5555 device model:MiTV_MFFU0\n192.168.1.101:5555 unauthorized\n192.168.1.102:5555 offline\nemulator-5554 device\nusb-1 device");
Check(devices.Count == 3 && devices[0].Ready && !devices[1].Ready && !devices[2].Ready, "only network devices, correct states");
Check(devices[0].Name == "MiTV MFFU0", "model parsing");
Check(AdbClient.ParseServices("tv _adb-tls-connect._tcp. 192.168.1.100:37000\ntv _adb-tls-pairing._tcp. 192.168.1.100:38000").Single().Port == 37000, "separate connection from pairing service");
Check(new Lan("LAN", "192.168.1.145", 0xffffff00).Hosts().Length == 253, "/24 excludes own, network, broadcast");
Check(new Lan("LAN", "192.168.1.145", 0xfffffff8).Hosts().SequenceEqual(new[] { "192.168.1.146", "192.168.1.147", "192.168.1.148", "192.168.1.149", "192.168.1.150" }), "actual /29 scan");
Check(new Lan("LAN", "10.3.4.5", 0xffff0000).Hosts().Length == 253, "bound large subnet");
Check(new Lan("LAN", "10.3.4.5", 0xffffffff).Hosts().Length == 0, "/32 boundary");
Check(Errors.Friendly("INSTALL_FAILED_UPDATE_INCOMPATIBLE").Contains("签名"), "signature failure");
Check(Errors.Friendly("INSTALL_FAILED_MISSING_SPLIT").Contains("拆分"), "missing split failure");

Check(DeviceCommands.Packages("package:com.example.b\npackage:com.example.a\npackage:com.example.a\npackage:com.bad;reboot").SequenceEqual(new[]{"com.example.a","com.example.b"}),"clean package inventory");
foreach(string bad in new[]{"com.x;reboot","com.x$(id)","com.x\nreboot","../foo","com.x'"})Reject(()=>DeviceCommands.Package(bad));
Check(DeviceCommands.Component("priority=0\ncom.example/.Main$Nested\n")=="com.example/.Main$Nested","component parsing");
Check(DeviceCommands.Component("com.example/.Main;reboot")==null,"component injection rejection");
Check(DeviceCommands.Checked("Success\n\n__TOOLS_EXIT:0\n")=="Success","remote exit marker");
foreach(string bad in new[]{"Success","Failure [DENIED]\n__TOOLS_EXIT:0\n","Error: denied\n__TOOLS_EXIT:0\n","denied\n__TOOLS_EXIT:1\n"})Reject(()=>DeviceCommands.Checked(bad));
Reject(()=>DeviceCommands.Key("KEYCODE_HOME;reboot"));
Check(!DeviceCommands.ValidPng(Encoding.UTF8.GetBytes("error")),"invalid screenshot rejected");
string directory = Path.Combine(Path.GetTempPath(), "tv-installer-tests-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
try
{
    string path = Path.Combine(directory, "应用 ' with $(literal).apk"); File.WriteAllBytes(path, new byte[] { 0x50, 0x4b, 3, 4, 0 });
    var installArgs = AdbClient.InstallArguments("192.168.1.100:5555", [path], false);
    Check(installArgs.SequenceEqual(new[] { "-s", "192.168.1.100:5555", "install", "-r", path }), "target and filename remain separate arguments");
    Check(AdbClient.InstallArguments("192.168.1.100:5555", [path, path], true)[2] == "install-multiple", "split command");
    Reject(() => AdbClient.InstallArguments("", [path], false));
    string bad = Path.Combine(directory,"bad.apk");File.WriteAllText(bad,"HTML instead of APK");Reject(()=>AdbClient.ValidateApk(bad));
    if (!OperatingSystem.IsWindows())
    {
        string script=Path.Combine(directory,"fake-adb");File.WriteAllText(script,"#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\"; done\nprintf 'Success\\n'\n");File.SetUnixFileMode(script,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        var result=await new AdbClient(script).Run(installArgs);Check(result.Success&&result.Output.Contains(path),"special filenames reach process literally");
        File.WriteAllText(script,"#!/bin/sh\nprintf 'Failure [INSTALL_FAILED_NO_MATCHING_ABIS]\\n'\nexit 1\n");
        result=await new AdbClient(script).Run(installArgs);Check(!result.Success&&Errors.Friendly(result.Output).Contains("架构"),"failed exit and error explanation");
        File.WriteAllText(script,"#!/bin/sh\nexec /bin/sleep 20\n");var start=DateTime.UtcNow;result=await new AdbClient(script).Run([],1);Check(result.TimedOut&&!result.Success&&DateTime.UtcNow-start<TimeSpan.FromSeconds(4),"kill only timed out client");
    }
}
finally { Directory.Delete(directory,true); }
await WindowsTroubleshootingTests.Run(Check,Reject);
Console.WriteLine($"PASS: {checks} Windows core checks");
