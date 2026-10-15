package com.enderkidleaf.tvinstaller;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;
import static com.enderkidleaf.tvinstaller.AndroidCoreTests.*;
public class AndroidTroubleshootingTests {
    static String open(Socket socket)throws Exception{
        AdbCore.Frame hello=AdbCore.Frame.read(socket.getInputStream());check(hello.command==AdbCore.CNXN,"terminal handshake");
        AdbCore.Frame.write(socket.getOutputStream(),AdbCore.CNXN,0x01000000,4096,"device::".getBytes(StandardCharsets.UTF_8));AdbCore.Frame request=AdbCore.Frame.read(socket.getInputStream());String command=new String(request.data,StandardCharsets.UTF_8);check(request.command==AdbCore.OPEN&&command.startsWith("shell:(\n"),"terminal uses target shell service");Matcher matcher=Pattern.compile("__ADB_TERM_[a-f0-9]+").matcher(command);check(matcher.find(),"random remote exit marker");AdbCore.Frame.write(socket.getOutputStream(),AdbCore.OKAY,77,1,new byte[0]);return matcher.group();
    }
    static void send(Socket socket,byte[] data)throws Exception{AdbCore.Frame.write(socket.getOutputStream(),AdbCore.WRTE,77,1,data);check(AdbCore.Frame.read(socket.getInputStream()).command==AdbCore.OKAY,"terminal output ack");}
    public static void run(AdbCore.Keys keys)throws Exception{
        for(String bad:new String[]{"","\0",String.join("",Collections.nCopies(8193,"x"))})reject(()->TroubleshootingCore.validate(bad));
        TroubleshootingCore.Parsed parsed=TroubleshootingCore.parse("error\nMARK:7\n","MARK");check(parsed.text.equals("error")&&parsed.code==7,"remote exit parsed");check(TroubleshootingCore.parse("partial","MARK").code==null,"missing marker not success");
        server(socket->{String marker=open(socket);byte[] data=("中文输出\n"+marker+":7\n").getBytes(StandardCharsets.UTF_8);send(socket,Arrays.copyOfRange(data,0,2));send(socket,Arrays.copyOfRange(data,2,data.length));AdbCore.Frame.write(socket.getOutputStream(),AdbCore.CLSE,77,1,new byte[0]);},endpoint->{List<String> snapshots=new ArrayList<>();TroubleshootingCore.Result result=TroubleshootingCore.execute(endpoint,keys,"exit 7",new TroubleshootingCore.Control(),m->{},snapshots::add,3000,4096);check(result.text.equals("中文输出")&&result.code==7&&!result.success,"fragmented UTF8 preserved and nonzero code shown");check(!snapshots.isEmpty(),"live snapshots delivered");});
        for(boolean timeout:new boolean[]{false,true}){
            final TroubleshootingCore.Control control=new TroubleshootingCore.Control();ScheduledExecutorService timer=Executors.newSingleThreadScheduledExecutor();
            try{server(socket->{open(socket);send(socket,"partial\n".getBytes(StandardCharsets.UTF_8));if(!timeout)timer.schedule(control::stop,100,TimeUnit.MILLISECONDS);check(socket.getInputStream().read()==-1,"stop closes only current connection");},endpoint->{TroubleshootingCore.Result result=TroubleshootingCore.execute(endpoint,keys,"sleep 20",control,m->{},m->{},timeout?500:3000,4096);check(!result.success&&result.text.contains("partial")&&result.status.contains(timeout?"时间":"停止"),"cancel or deadline retains partial output");});}finally{timer.shutdownNow();}
        }
        server(socket->{open(socket);send(socket,new byte[5000]);},endpoint->{TroubleshootingCore.Result result=TroubleshootingCore.execute(endpoint,keys,"flood",new TroubleshootingCore.Control(),m->{},m->{},3000,1024);check(!result.success&&result.text.length()<=1024&&result.status.contains("输出"),"output bounded");});
        TroubleshootingCore.Control cancelled=new TroubleshootingCore.Control();cancelled.stop();TroubleshootingCore.Result skipped=TroubleshootingCore.execute(new AdbCore.Endpoint("127.0.0.1",1),keys,"echo test",cancelled,m->{},m->{},500,4096);check(skipped.status.contains("停止"),"pre-cancel never connects");
        final TroubleshootingCore.Control handshakeStop=new TroubleshootingCore.Control();ScheduledExecutorService timer=Executors.newSingleThreadScheduledExecutor();
        try{server(socket->{AdbCore.Frame.read(socket.getInputStream());timer.schedule(handshakeStop::stop,100,TimeUnit.MILLISECONDS);check(socket.getInputStream().read()==-1,"cancel during handshake closes socket");},endpoint->{TroubleshootingCore.Result result=TroubleshootingCore.execute(endpoint,keys,"echo test",handshakeStop,m->{},m->{},3000,4096);check(result.status.contains("停止"),"handshake cancellation surfaced");});}finally{timer.shutdownNow();}
    }
}
