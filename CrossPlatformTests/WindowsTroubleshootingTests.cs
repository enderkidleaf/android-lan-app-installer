using TVAppInstaller;
public static class WindowsTroubleshootingTests
{
    public static async Task Run(Action<bool,string> check,Action<Action> reject)
    {
        const string target="192.0.2.1:5555";
        async Task<(DiagnosisReport,List<string>)> Scenario(string mode,bool repair=true)
        {
            bool healed=mode.StartsWith("healthy",StringComparison.Ordinal);int inventory=0;List<string> calls=[];
            var doctor=new ConnectionDoctor((args,_)=>{
                string call=string.Join(' ',args);calls.Add(call);
                if(call=="devices -l"){
                    inventory++;if(mode=="badInventory")return Task.FromResult(new CommandResult(0,"unknown"));
                    string row=healed?target+" device\n":"";
                    if(mode=="unauthorized")row=target+" unauthorized\n";
                    if(mode=="usb"||(mode=="race"&&inventory>=3))row+="USB_DEVICE device\n";
                    if(mode=="emulator")row+="emulator-5554 offline\n";
                    return Task.FromResult(new CommandResult(0,"List of devices attached\n"+row));
                }
                if(call=="kill-server")return Task.FromResult(new CommandResult(0,""));
                if(call=="start-server"){if(mode=="startFailure")return Task.FromResult(new CommandResult(1,"cannot start"));healed=true;}
                if(call==$"-s {target} shell echo ADB_DIAG_OK")return Task.FromResult(new CommandResult(0,"ADB_DIAG_OK\n"));
                return Task.FromResult(new CommandResult(healed?0:1,healed?"connected":"No route to host"));
            },_=>Task.FromResult(mode!="closedPort"&&mode!="healthyProbeBlocked"),_=>{});
            return(await doctor.Diagnose(target,repair),calls);
        }
        var healthy=await Scenario("healthy");check(healthy.Item1.Connected&&!healthy.Item2.Contains("kill-server"),"healthy does not restart");
        var blocked=await Scenario("healthyProbeBlocked");check(blocked.Item1.Connected&&blocked.Item1.Summary.Contains("探测受阻")&&!blocked.Item2.Contains("kill-server"),"working ADB takes precedence over blocked probe");
        var stale=await Scenario("stale");check(stale.Item1.Connected&&stale.Item2.Count(x=>x=="kill-server")==1,"stale service repaired once and verified");
        var readonlyCheck=await Scenario("stale",false);check(readonlyCheck.Item1.RestartAllowed&&!readonlyCheck.Item2.Contains("kill-server"),"check only does not restart");
        foreach(string mode in new[]{"unauthorized","usb","emulator","closedPort","badInventory","race"}){var value=await Scenario(mode);check(!value.Item1.Connected&&!value.Item2.Contains("kill-server"),"protect "+mode);}
        var fail=await Scenario("startFailure");check(!fail.Item1.Connected&&fail.Item1.Summary.Contains("启动"),"start failure surfaced");
        foreach(string bad in new[]{"","\0",new string('x',8193)})reject(()=>TerminalCodec.Validate(bad));
        var parsed=TerminalCodec.Parse("error\nMARK:7\n","MARK");check(parsed.Text=="error"&&parsed.Code==7,"remote exit marker");check(TerminalCodec.Parse("partial","MARK").Code==null,"missing marker not success");
        if(!OperatingSystem.IsWindows()){
            string directory=Path.Combine(Path.GetTempPath(),"troubleshooting-"+Guid.NewGuid());Directory.CreateDirectory(directory);
            try{
                string script=Path.Combine(directory,"fake-adb");await File.WriteAllTextAsync(script,"#!/bin/sh\n[ \"$1\" = '-s' ] && [ \"$2\" = '"+target+"' ] && [ \"$3\" = 'shell' ] || exit 9\nexec /bin/sh -c \"$4\"\n");File.SetUnixFileMode(script,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);var adb=new AdbClient(script);
                var value=await adb.ConsoleRun(["-s",target,"shell",TerminalCodec.Wrap("printf 'first\\n'; printf 'problem\\n' >&2; exit 7","MARK")],3,CancellationToken.None);parsed=TerminalCodec.Parse(value.Output,"MARK");check(parsed.Text.Contains("first")&&parsed.Text.Contains("problem")&&parsed.Code==7,"literal target command and stderr with remote exit");
                await File.WriteAllTextAsync(script,"#!/bin/sh\nprintf 'partial\\n'\nexec /bin/sleep 20\n");using var stop=new CancellationTokenSource();var begin=DateTime.UtcNow;value=await adb.ConsoleRun([],5,stop.Token,text=>{if(text.Contains("partial"))stop.CancelAfter(50);});check(value.Cancelled&&value.Output.Contains("partial")&&DateTime.UtcNow-begin<TimeSpan.FromSeconds(3),"stop retains partial output");
                using var cancelled=new CancellationTokenSource();cancelled.Cancel();value=await adb.ConsoleRun([],5,cancelled.Token);check(value.Cancelled&&value.Output.Length==0,"pre-cancel does not execute");
                await File.WriteAllTextAsync(script,"#!/bin/sh\nexec /usr/bin/yes output\n");value=await adb.ConsoleRun([],3,CancellationToken.None,limit:4096);check(value.OutputLimited&&System.Text.Encoding.UTF8.GetByteCount(value.Output)<=4096,"bounded output");
                await File.WriteAllTextAsync(script,"#!/bin/sh\nprintf 'live\\n'\nexec /bin/sleep 0.2\n");List<string> snapshots=[];await adb.ConsoleRun([],3,CancellationToken.None,s=>snapshots.Add(s));check(snapshots.Any(s=>s.Contains("live")),"live output callback");
            }finally{Directory.Delete(directory,true);}
        }
    }
}
