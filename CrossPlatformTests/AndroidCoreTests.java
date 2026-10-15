package com.enderkidleaf.tvinstaller;
import java.io.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import javax.crypto.Cipher;

public class AndroidCoreTests {
    static final java.util.concurrent.atomic.AtomicInteger checks=new java.util.concurrent.atomic.AtomicInteger();
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);checks.incrementAndGet();}
    interface Throwing {void run()throws Exception;}
    static void reject(Throwing action)throws Exception{try{action.run();}catch(Exception e){checks.incrementAndGet();return;}throw new AssertionError("Expected rejection");}
    interface ServerAction {void run(Socket socket)throws Exception;}
    static void server(ServerAction action,ThrowingClient client)throws Exception{
        try(ServerSocket server=new ServerSocket(0,1,InetAddress.getByName("127.0.0.1"))){
            ExecutorService worker=Executors.newSingleThreadExecutor();
            Future<?> task=worker.submit(()->{try(Socket socket=server.accept()){socket.setSoTimeout(5000);action.run(socket);}catch(Exception e){throw new RuntimeException(e);}});
            try{client.run(new AdbCore.Endpoint("127.0.0.1",server.getLocalPort()));task.get(8,TimeUnit.SECONDS);}finally{worker.shutdownNow();}
        }
    }
    interface ThrowingClient{void run(AdbCore.Endpoint endpoint)throws Exception;}
    static void handshake(Socket socket)throws Exception{
        AdbCore.Frame hello=AdbCore.Frame.read(socket.getInputStream());check(hello.command==AdbCore.CNXN,"client handshake");
        AdbCore.Frame.write(socket.getOutputStream(),AdbCore.CNXN,0x01000000,4096,"device::".getBytes(StandardCharsets.UTF_8));
        AdbCore.Frame open=AdbCore.Frame.read(socket.getInputStream());check(open.command==AdbCore.OPEN&&open.arg0==1,"open service with local stream id");
        AdbCore.Frame.write(socket.getOutputStream(),AdbCore.OKAY,77,1,new byte[0]);
    }
    public static void main(String[] args)throws Exception{
        check(AdbCore.Endpoint.parse(" 192.168.1.100 ").address().equals("192.168.1.100:5555"),"default endpoint");
        check(AdbCore.Endpoint.parse("192.168.1.100:39000").port==39000,"custom port");
        for(String value:new String[]{"","192.168.1.999","192.168.1","127.0.0.1","0.0.0.0","224.0.0.1","192.168.1.1:0","192.168.1.1:65536","192.168.1.1;echo hi"})reject(()->AdbCore.Endpoint.parse(value));
        check(new AdbCore.Lan("LAN","192.168.1.145",24).hosts().size()==253,"/24 scan bound");
        check(new AdbCore.Lan("LAN","192.168.1.145",29).hosts().equals(Arrays.asList("192.168.1.146","192.168.1.147","192.168.1.148","192.168.1.149","192.168.1.150")),"actual /29");
        check(new AdbCore.Lan("LAN","10.3.4.5",16).hosts().size()==253,"large subnet bounded");
        check(new AdbCore.Lan("LAN","10.3.4.5",32).hosts().isEmpty(),"/32 boundary");
        AdbCore.Keys keys=AdbCore.Keys.generate();byte[] token=new byte[20];new SecureRandom().nextBytes(token);
        Cipher rsa=Cipher.getInstance("RSA/ECB/PKCS1Padding");rsa.init(Cipher.DECRYPT_MODE,keys.publicKey);byte[] decoded=rsa.doFinal(keys.sign(token));
        check(decoded.length==35&&Arrays.equals(Arrays.copyOfRange(decoded,15,35),token),"sign existing SHA1 token without hashing it again");
        byte[] publicStruct=Base64.getDecoder().decode(new String(keys.adbPublicKey(),StandardCharsets.US_ASCII).split(" ")[0]);
        check(publicStruct.length==524&&ByteBuffer.wrap(publicStruct).order(ByteOrder.LITTLE_ENDIAN).getInt()==64,"Android 2048-bit public-key wire format");
        reject(()->keys.sign(new byte[32]));
        Path directory=Files.createTempDirectory("tv-adb-keys-");try{AdbCore.Keys a=AdbCore.Keys.load(directory.toFile()),b=AdbCore.Keys.load(directory.toFile());check(Arrays.equals(a.adbPublicKey(),b.adbPublicKey()),"persistent trust key across restarts");}finally{for(File f:directory.toFile().listFiles())f.delete();directory.toFile().delete();}
        ByteArrayOutputStream wire=new ByteArrayOutputStream();AdbCore.Frame.write(wire,AdbCore.WRTE,1,2,new byte[]{1,2,3});AdbCore.Frame frame=AdbCore.Frame.read(new ByteArrayInputStream(wire.toByteArray()));check(frame.command==AdbCore.WRTE&&frame.arg0==1&&Arrays.equals(frame.data,new byte[]{1,2,3}),"frame encode/decode");
        byte[] corrupt=wire.toByteArray();corrupt[20]^=1;reject(()->AdbCore.Frame.read(new ByteArrayInputStream(corrupt)));
        byte[] huge=wire.toByteArray();ByteBuffer.wrap(huge).order(ByteOrder.LITTLE_ENDIAN).putInt(12,2*1024*1024);reject(()->AdbCore.Frame.read(new ByteArrayInputStream(huge)));
        java.util.concurrent.atomic.AtomicInteger notices=new java.util.concurrent.atomic.AtomicInteger();
        server(socket->{
            AdbCore.Frame.read(socket.getInputStream());AdbCore.Frame.write(socket.getOutputStream(),AdbCore.AUTH,1,0,token);
            AdbCore.Frame signature=AdbCore.Frame.read(socket.getInputStream());check(signature.command==AdbCore.AUTH&&signature.arg0==2,"sign first authorization challenge");
            Cipher verifier=Cipher.getInstance("RSA/ECB/PKCS1Padding");verifier.init(Cipher.DECRYPT_MODE,keys.publicKey);check(Arrays.equals(Arrays.copyOfRange(verifier.doFinal(signature.data),15,35),token),"wire signature matches challenge");
            AdbCore.Frame.write(socket.getOutputStream(),AdbCore.AUTH,1,0,token);AdbCore.Frame publicKey=AdbCore.Frame.read(socket.getInputStream());check(publicKey.command==AdbCore.AUTH&&publicKey.arg0==3&&Arrays.equals(publicKey.data,keys.adbPublicKey()),"send trust key after unknown signature");
            AdbCore.Frame.write(socket.getOutputStream(),AdbCore.CNXN,0x01000000,4096,"device::".getBytes(StandardCharsets.UTF_8));
        },endpoint->{try(AdbCore.Connection connection=new AdbCore.Connection(endpoint,keys,m->notices.incrementAndGet())){check(notices.get()==1,"prompt once for television authorization");}});
        server(socket->{handshake(socket);byte[] output="电视型号测试\n".getBytes(StandardCharsets.UTF_8);AdbCore.Frame.write(socket.getOutputStream(),AdbCore.WRTE,77,1,Arrays.copyOfRange(output,0,2));check(AdbCore.Frame.read(socket.getInputStream()).command==AdbCore.OKAY,"ack first shell chunk");AdbCore.Frame.write(socket.getOutputStream(),AdbCore.WRTE,77,1,Arrays.copyOfRange(output,2,output.length));check(AdbCore.Frame.read(socket.getInputStream()).command==AdbCore.OKAY,"ack second shell chunk");AdbCore.Frame.write(socket.getOutputStream(),AdbCore.CLSE,77,1,new byte[0]);},endpoint->{String result=AdbCore.shell(endpoint,keys,"getprop ro.product.model",5000,m->{});check(result.equals("电视型号测试\n"),"UTF-8 survives fragmented packets");});
        byte[] file=new byte[9000];new Random(3).nextBytes(file);
        server(socket->{
            handshake(socket);ByteArrayOutputStream payload=new ByteArrayOutputStream();
            while(true){AdbCore.Frame packet=AdbCore.Frame.read(socket.getInputStream());check(packet.command==AdbCore.WRTE,"sync write");payload.write(packet.data);boolean done=packet.data.length==8&&new String(packet.data,0,4,StandardCharsets.US_ASCII).equals("DONE");
                if(done){AdbCore.Frame.write(socket.getOutputStream(),AdbCore.WRTE,77,1,AdbCore.sync("OKAY",0,new byte[0]));AdbCore.Frame.write(socket.getOutputStream(),AdbCore.OKAY,77,1,new byte[0]);check(AdbCore.Frame.read(socket.getInputStream()).command==AdbCore.OKAY,"ack response before write ack");break;}
                AdbCore.Frame.write(socket.getOutputStream(),AdbCore.OKAY,77,1,new byte[0]);
            }
            ByteBuffer stream=ByteBuffer.wrap(payload.toByteArray()).order(ByteOrder.LITTLE_ENDIAN);check(stream.getInt()==0x444e4553,"sync SEND");int nameLength=stream.getInt();stream.position(stream.position()+nameLength);check(stream.getInt()==0x41544144,"sync DATA");int count=stream.getInt();byte[] copy=new byte[count];stream.get(copy);check(Arrays.equals(copy,file),"file content survives transport chunking");
        },endpoint->{try(AdbCore.Connection connection=new AdbCore.Connection(endpoint,keys,m->{})){connection.push(new ByteArrayInputStream(file),file.length,"/data/local/tmp/test.bin",(done,total)->{});check(true,"sync upload success");}});
        server(socket->{AdbCore.Frame.read(socket.getInputStream());AdbCore.Frame.write(socket.getOutputStream(),AdbCore.STLS,1,1,new byte[0]);},endpoint->reject(()->new AdbCore.Connection(endpoint,keys,m->{})));
        check(AdbCore.friendly("INSTALL_FAILED_UPDATE_INCOMPATIBLE").contains("签名"),"explain signature failure");

        check(DeviceCommands.packages("package:com.example.b\npackage:com.example.a\npackage:com.example.a\npackage:com.bad;reboot").equals(Arrays.asList("com.example.a","com.example.b")),"clean package inventory");
        for(String bad:new String[]{"com.x;reboot","com.x$(id)","com.x\nreboot","../foo","com.x'"})reject(()->DeviceCommands.pkg(bad));
        check(DeviceCommands.component("priority=0\ncom.example/.Main$Nested\n").equals("com.example/.Main$Nested"),"component parsing");
        check(DeviceCommands.component("com.example/.Main;reboot")==null,"component injection rejection");
        check(DeviceCommands.checked("Success\n\n__TOOLS_EXIT:0\n").equals("Success"),"remote exit marker");
        for(String bad:new String[]{"Success","Failure [DENIED]\n__TOOLS_EXIT:0\n","Error: denied\n__TOOLS_EXIT:0\n","denied\n__TOOLS_EXIT:1\n"})reject(()->DeviceCommands.checked(bad));
        reject(()->DeviceCommands.key("KEYCODE_HOME;reboot"));
        check(!DeviceCommands.validPng("error".getBytes(StandardCharsets.UTF_8)),"invalid screenshot rejected");
        final byte[] binary=new byte[]{(byte)137,80,78,71,13,10,26,10,0,0,0,0,0,(byte)255,(byte)128,0,0,0,0,0,0,0,0,0,0};
        server(socket->{handshake(socket);for(int i=0;i<binary.length;i++){AdbCore.Frame.write(socket.getOutputStream(),AdbCore.WRTE,77,1,new byte[]{binary[i]});AdbCore.Frame.read(socket.getInputStream());}AdbCore.Frame.write(socket.getOutputStream(),AdbCore.CLSE,77,1,new byte[0]);},endpoint->{try(AdbCore.Connection c=new AdbCore.Connection(endpoint,keys,m->{})){c.open("exec:screencap -p");byte[] bytes=c.readAll(32*1024*1024);check(Arrays.equals(binary,bytes)&&DeviceCommands.validPng(bytes),"screenshot binary survives fragmented transport without UTF8 conversion");}});
        System.out.println("PASS: "+checks.get()+" Android protocol checks");
    }
}
