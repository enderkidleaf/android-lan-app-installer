package com.enderkidleaf.tvinstaller;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
public final class TroubleshootingCore {
    private TroubleshootingCore(){}
    public static String validate(String command)throws IOException {if(command.trim().isEmpty()||command.getBytes(StandardCharsets.UTF_8).length>8192||command.indexOf('\0')>=0)throw new IOException("请输入一条命令，最多 8192 字节，不能包含空字符。");return command;}
    public static String wrap(String command,String marker)throws IOException{return "(\n"+validate(command)+"\n); result=$?; printf '\\n"+marker+":%s\\n' \"$result\"";}
    public static class Parsed {public final String text;public final Integer code;Parsed(String t,Integer c){text=t;code=c;}}
    public static Parsed parse(String output,String marker){int index=output.lastIndexOf("\n"+marker+":");if(index>=0)try{return new Parsed(output.substring(0,index),Integer.valueOf(output.substring(index+marker.length()+2).trim()));}catch(NumberFormatException ignored){}return new Parsed(output,null);}
    public static class Control {
        volatile boolean cancelled,expired;volatile AdbCore.Connection connection;
        public void stop(){cancelled=true;AdbCore.Connection c=connection;if(c!=null)c.close();}
        void expire(){expired=true;AdbCore.Connection c=connection;if(c!=null)c.close();}
        void attach(AdbCore.Connection c){connection=c;if(cancelled||expired)c.close();}
    }
    public static class Result {
        public final String text,status;public final Integer code;public final boolean success;
        Result(String text,Integer code,String status,boolean success){this.text=text;this.code=code;this.status=status;this.success=success;}
    }
    public static boolean probe(AdbCore.Endpoint endpoint){return probe(endpoint,m->{});}
    public static boolean probe(AdbCore.Endpoint endpoint,AdbCore.Notice report){try(Socket s=new Socket()){s.connect(new InetSocketAddress(endpoint.host,endpoint.port),1800);return true;}catch(IOException e){report.update(e instanceof NoRouteToHostException?"网络无法到达目标设备。":e instanceof ConnectException?"端口拒绝连接，请检查网络 ADB 开关和端口。":e instanceof SocketTimeoutException?"连接端口超时，请检查设备电源、IP 和网络隔离。":"端口检查失败："+e.getMessage());return false;}}
    public static Result execute(AdbCore.Endpoint endpoint,AdbCore.Keys keys,String command,Control control,AdbCore.Notice notice,AdbCore.Notice output)throws Exception{return execute(endpoint,keys,command,control,notice,output,60000,256*1024);}
    public static Result execute(AdbCore.Endpoint endpoint,AdbCore.Keys keys,String command,Control control,AdbCore.Notice notice,AdbCore.Notice output,int milliseconds,int limit)throws Exception{
        String marker="__ADB_TERM_"+UUID.randomUUID().toString().replace("-","");String service="shell:"+wrap(command,marker);ByteArrayOutputStream bytes=new ByteArrayOutputStream();boolean limited=false;String error=null;
        if(control.cancelled)return new Result("",null,"已停止当前命令。",false);
        ScheduledExecutorService timer=Executors.newSingleThreadScheduledExecutor();ScheduledFuture<?> deadline=timer.schedule(control::expire,milliseconds,TimeUnit.MILLISECONDS);
        try(AdbCore.Connection connection=new AdbCore.Connection(endpoint,keys,notice,control::attach)){
            connection.timeout(milliseconds+1000);connection.open(service);byte[] chunk;
            while((chunk=connection.readChunk())!=null){int room=limit-bytes.size();bytes.write(chunk,0,Math.min(room,chunk.length));output.update(parse(new String(bytes.toByteArray(),StandardCharsets.UTF_8),marker).text);if(chunk.length>room){limited=true;break;}if(control.cancelled||control.expired)break;}
        }catch(Exception e){if(!control.cancelled&&!control.expired)error=AdbCore.friendly(e.getMessage());}
        finally{deadline.cancel(false);timer.shutdownNow();control.connection=null;}
        Parsed parsed=parse(new String(bytes.toByteArray(),StandardCharsets.UTF_8),marker);
        String status=control.cancelled?"已停止当前命令。":control.expired?"命令超过时间限制，已停止。":limited?"输出达到 256 KB，已停止当前命令。":error!=null?error:"命令结束，退出码："+(parsed.code==null?"未返回":parsed.code);
        return new Result(parsed.text,parsed.code,status,!control.cancelled&&!control.expired&&!limited&&error==null&&Integer.valueOf(0).equals(parsed.code));
    }
}
