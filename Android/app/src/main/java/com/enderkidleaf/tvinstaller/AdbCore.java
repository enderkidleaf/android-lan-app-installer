package com.enderkidleaf.tvinstaller;

import java.io.*;
import java.math.BigInteger;
import java.net.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.interfaces.RSAPrivateCrtKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.RSAPublicKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import javax.crypto.Cipher;

/** Classic TCP ADB transport. One stream per connection, bounded messages, persistent RSA trust. */
public final class AdbCore {
    private AdbCore() {}
    public interface Progress { void update(long done, long total); }
    public interface Notice { void update(String text); }
    public static final int CNXN=0x4e584e43, AUTH=0x48545541, OPEN=0x4e45504f,
            OKAY=0x59414b4f, CLSE=0x45534c43, WRTE=0x45545257, STLS=0x534c5453;

    public static final class Endpoint {
        public final String host; public final int port;
        public Endpoint(String host, int port) { this.host=host; this.port=port; }
        public String address() { return host+":"+port; }
        public static Endpoint parse(String input) {
            String[] parts=input.trim().split(":",-1);
            if (parts.length<1 || parts.length>2 || !parts[0].matches("[0-9]{1,3}(\\.[0-9]{1,3}){3}")) throw new IllegalArgumentException("请输入设备 IPv4 地址，例如 192.168.1.100:5555。");
            String[] octets=parts[0].split("\\."); int first=Integer.parseInt(octets[0]);
            if (first==0 || first==127 || first>=224) throw new IllegalArgumentException("请输入设备的局域网 IP。");
            StringBuilder host=new StringBuilder();
            for (String value:octets) { int n=Integer.parseInt(value); if(n>255) throw new IllegalArgumentException("IP 地址不正确。"); if(host.length()>0) host.append('.'); host.append(n); }
            int port=5555;
            if(parts.length==2) { try { port=Integer.parseInt(parts[1]); } catch(NumberFormatException e) { throw new IllegalArgumentException("端口不正确。"); } }
            if(port<1 || port>65535) throw new IllegalArgumentException("端口应在 1 到 65535 之间。");
            return new Endpoint(host.toString(),port);
        }
    }

    public static final class Lan {
        public final String name,ip; public final int prefix;
        public Lan(String name,String ip,int prefix){this.name=name;this.ip=ip;this.prefix=prefix;}
        public String toString(){return name+" · "+ip+"/"+prefix;}
        public List<String> hosts(){
            int effective=Math.max(24,Math.min(32,prefix)); long own=ipNumber(ip), mask=effective==32?0xffffffffL:(0xffffffffL<<(32-effective))&0xffffffffL;
            long start=own&mask,end=start|(~mask&0xffffffffL); List<String> result=new ArrayList<>();
            for(long n=start+1;n<end;n++)if(n!=own)result.add(ipText(n)); return result;
        }
        public static List<Lan> current() throws SocketException {
            List<Lan> result=new ArrayList<>(); Enumeration<NetworkInterface> interfaces=NetworkInterface.getNetworkInterfaces();
            if(interfaces==null)return result;
            while(interfaces.hasMoreElements()){
                NetworkInterface nic=interfaces.nextElement(); String name=nic.getName();
                if(!nic.isUp() || nic.isLoopback() || name.startsWith("tun") || name.startsWith("rmnet") || name.startsWith("pdp"))continue;
                for(InterfaceAddress address:nic.getInterfaceAddresses())if(address.getAddress() instanceof Inet4Address){
                    String ip=address.getAddress().getHostAddress(); if(!ip.startsWith("169.254.")) result.add(new Lan(name,ip,address.getNetworkPrefixLength()));
                }
            }
            return result;
        }
    }
    static long ipNumber(String ip){long n=0;for(String part:ip.split("\\."))n=(n<<8)|Integer.parseInt(part);return n;}
    static String ipText(long n){return ((n>>24)&255)+"."+((n>>16)&255)+"."+((n>>8)&255)+"."+(n&255);}
    public static List<Endpoint> discover(Lan lan,Progress progress) throws InterruptedException,ExecutionException {
        List<String> hosts=lan.hosts(); ExecutorService pool=Executors.newFixedThreadPool(24);
        List<Future<Endpoint>> tasks=new ArrayList<>(); AtomicInteger count=new AtomicInteger();
        try{
            for(final String host:hosts) tasks.add(pool.submit(()->{
                try(Socket socket=new Socket()){socket.connect(new InetSocketAddress(host,5555),650);return new Endpoint(host,5555);}
                catch(IOException e){return null;} finally{progress.update(count.incrementAndGet(),hosts.size());}
            }));
            List<Endpoint> result=new ArrayList<>();for(Future<Endpoint> task:tasks){Endpoint endpoint=task.get();if(endpoint!=null)result.add(endpoint);}return result;
        }finally{pool.shutdownNow();}
    }

    public static final class Keys {
        final PrivateKey privateKey; final RSAPublicKey publicKey;
        public Keys(PrivateKey privateKey,PublicKey publicKey){this.privateKey=privateKey;this.publicKey=(RSAPublicKey)publicKey;}
        public static Keys generate() throws GeneralSecurityException {KeyPairGenerator gen=KeyPairGenerator.getInstance("RSA");gen.initialize(2048);KeyPair pair=gen.generateKeyPair();return new Keys(pair.getPrivate(),pair.getPublic());}
        public static Keys load(File directory) throws IOException,GeneralSecurityException {
            File secret=new File(directory,"adb-private.pk8"), pub=new File(directory,"adb-public.x509");
            if(secret.exists() && pub.exists()){
                KeyFactory factory=KeyFactory.getInstance("RSA");
                return new Keys(factory.generatePrivate(new PKCS8EncodedKeySpec(readFile(secret))),factory.generatePublic(new X509EncodedKeySpec(readFile(pub))));
            }
            Keys keys=generate(); directory.mkdirs(); writeFile(secret,keys.privateKey.getEncoded());writeFile(pub,keys.publicKey.getEncoded());return keys;
        }
        /** Diagnostic only: import an already-authorized host key; never include it in an APK. */
        public static Keys fromPrivate(PrivateKey privateKey) throws GeneralSecurityException {
            RSAPrivateCrtKey rsa=(RSAPrivateCrtKey)privateKey;
            return new Keys(privateKey,KeyFactory.getInstance("RSA").generatePublic(new RSAPublicKeySpec(rsa.getModulus(),rsa.getPublicExponent())));
        }
        public byte[] sign(byte[] token) throws GeneralSecurityException {
            if(token.length!=20)throw new GeneralSecurityException("ADB 授权令牌长度不正确。");
            byte[] digestInfo={0x30,0x21,0x30,0x09,0x06,0x05,0x2b,0x0e,0x03,0x02,0x1a,0x05,0x00,0x04,0x14};
            byte[] message=new byte[digestInfo.length+token.length];System.arraycopy(digestInfo,0,message,0,digestInfo.length);System.arraycopy(token,0,message,digestInfo.length,token.length);
            Cipher rsa=Cipher.getInstance("RSA/ECB/PKCS1Padding");rsa.init(Cipher.ENCRYPT_MODE,privateKey);return rsa.doFinal(message);
        }
        public byte[] adbPublicKey(){
            BigInteger modulus=publicKey.getModulus(), base=BigInteger.ONE.shiftLeft(32);
            ByteBuffer buffer=ByteBuffer.allocate(524).order(ByteOrder.LITTLE_ENDIAN);
            buffer.putInt(64).putInt(modulus.modInverse(base).negate().intValue());
            buffer.put(littleEndian(modulus,256));buffer.put(littleEndian(BigInteger.ONE.shiftLeft(4096).mod(modulus),256));buffer.putInt(publicKey.getPublicExponent().intValue());
            return (Base64.getEncoder().encodeToString(buffer.array())+" tv-installer@android\0").getBytes(StandardCharsets.US_ASCII);
        }
        static byte[] littleEndian(BigInteger value,int length){byte[] big=value.toByteArray(),result=new byte[length];for(int i=0;i<length && i<big.length;i++)result[i]=big[big.length-1-i];return result;}
        static byte[] readFile(File file)throws IOException{try(InputStream input=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[2048];int n;while((n=input.read(b))!=-1){out.write(b,0,n);if(out.size()>8192)throw new IOException("ADB 密钥文件过大。");}return out.toByteArray();}}
        static void writeFile(File file,byte[] data)throws IOException{File temporary=new File(file.getPath()+".tmp");try(OutputStream out=new FileOutputStream(temporary)){out.write(data);}if(!temporary.renameTo(file))throw new IOException("无法保存 ADB 信任密钥。");}
    }

    public static final class Frame {
        public final int command,arg0,arg1; public final byte[] data;
        Frame(int command,int arg0,int arg1,byte[] data){this.command=command;this.arg0=arg0;this.arg1=arg1;this.data=data;}
        public static void write(OutputStream output,int command,int arg0,int arg1,byte[] data)throws IOException{
            int checksum=0;for(byte b:data)checksum+=(b&255);
            ByteBuffer header=ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);header.putInt(command).putInt(arg0).putInt(arg1).putInt(data.length).putInt(checksum).putInt(command^0xffffffff);
            output.write(header.array());output.write(data);output.flush();
        }
        public static Frame read(InputStream input)throws IOException{
            ByteBuffer header=ByteBuffer.wrap(exact(input,24)).order(ByteOrder.LITTLE_ENDIAN);
            int command=header.getInt(),arg0=header.getInt(),arg1=header.getInt(),length=header.getInt(),checksum=header.getInt(),magic=header.getInt();
            if(magic!=(command^0xffffffff) || length<0 || length>1024*1024)throw new IOException("无效的 ADB 消息头。");
            byte[] data=exact(input,length);int actual=0;for(byte b:data)actual+=(b&255);
            // Modern ADB may explicitly omit checksums; verify any checksum that is present.
            if(checksum!=0 && checksum!=actual)throw new IOException("ADB 数据校验失败。");
            return new Frame(command,arg0,arg1,data);
        }
    }

    public static final class Connection implements Closeable {
        private final Socket socket=new Socket(); private InputStream input; private OutputStream output;
        private int remoteId,maxData=4096; private boolean opened;
        private final ArrayDeque<byte[]> pending=new ArrayDeque<>();
        public Connection(Endpoint endpoint,Keys keys,Notice notice)throws IOException,GeneralSecurityException{
            this(endpoint,keys,notice,connection->{});
        }
        public Connection(Endpoint endpoint,Keys keys,Notice notice,java.util.function.Consumer<Connection> started)throws IOException,GeneralSecurityException{
            try{
                started.accept(this);
                socket.connect(new InetSocketAddress(endpoint.host,endpoint.port),5000);socket.setTcpNoDelay(true);socket.setSoTimeout(60000);
                input=socket.getInputStream();output=socket.getOutputStream();
                Frame.write(output,CNXN,0x01000000,256*1024,"host::\0".getBytes(StandardCharsets.UTF_8));
                boolean signed=false,published=false;
                for(int attempt=0;attempt<12;attempt++){
                    Frame frame=Frame.read(input);
                    if(frame.command==CNXN){if(frame.arg1<4096)throw new IOException("设备的 ADB 数据容量不受支持。");maxData=Math.min(frame.arg1,256*1024);socket.setSoTimeout(30000);return;}
                    if(frame.command==STLS)throw new IOException("此端口使用配对式 TLS 无线调试。安卓端当前支持普通网络 ADB，请使用设备的 TCP 5555 调试端口；配对可用桌面客户端。");
                    if(frame.command==AUTH && frame.arg0==1){
                        if(!signed){Frame.write(output,AUTH,2,0,keys.sign(frame.data));signed=true;}
                        else if(!published){notice.update("请在设备的授权弹窗选择「允许」。正在等待确认…");Frame.write(output,AUTH,3,0,keys.adbPublicKey());published=true;}
                        else throw new IOException("设备尚未授权此手机，请确认设备弹窗后重试。");
                    }else throw new IOException("此端口没有返回可识别的 ADB 授权响应。");
                }
                throw new IOException("ADB 握手未完成。");
            }catch(IOException|GeneralSecurityException|RuntimeException e){close();throw e;}
        }
        public synchronized void timeout(int ms)throws SocketException{socket.setSoTimeout(ms);}
        public synchronized void open(String service)throws IOException{
            if(opened)throw new IOException("一个连接只能打开一个服务。");
            Frame.write(output,OPEN,1,0,(service+"\0").getBytes(StandardCharsets.UTF_8));Frame reply=Frame.read(input);
            if(reply.command!=OKAY || reply.arg1!=1)throw new IOException("设备拒绝打开服务："+service);
            remoteId=reply.arg0;opened=true;
        }
        void valid(Frame frame)throws IOException{if(frame.arg1!=1 || frame.arg0!=remoteId)throw new IOException("ADB 流标识不匹配。");}
        public void write(byte[] data)throws IOException{
            for(int offset=0;offset<data.length;offset+=maxData){
                byte[] chunk=Arrays.copyOfRange(data,offset,Math.min(data.length,offset+maxData));
                Frame.write(output,WRTE,1,remoteId,chunk);
                while(true){
                    Frame ack=Frame.read(input);valid(ack);
                    if(ack.command==OKAY)break;
                    if(ack.command==WRTE){if(pending.size()>=16)throw new IOException("ADB 响应队列过大。");Frame.write(output,OKAY,1,remoteId,new byte[0]);pending.add(ack.data);}
                    else throw new IOException("设备未确认文件传输。");
                }
            }
        }
        byte[] readChunk()throws IOException{
            if(!pending.isEmpty())return pending.removeFirst();
            Frame frame=Frame.read(input);valid(frame);
            if(frame.command==CLSE)return null;
            if(frame.command!=WRTE)throw new IOException("ADB 服务响应不正确。");
            Frame.write(output,OKAY,1,remoteId,new byte[0]);return frame.data;
        }
        public byte[] readAll(int limit)throws IOException{
            ByteArrayOutputStream result=new ByteArrayOutputStream();byte[] chunk;
            while((chunk=readChunk())!=null){if(result.size()+chunk.length>limit)throw new IOException("ADB 输出超过大小限制。");result.write(chunk);}return result.toByteArray();
        }
        public void push(InputStream source,long total,String destination,Progress progress)throws IOException{
            open("sync:");byte[] name=(destination+",33188").getBytes(StandardCharsets.UTF_8);write(sync("SEND",name.length,name));
            byte[] buffer=new byte[64*1024];long done=0;int n;
            while((n=source.read(buffer))!=-1){if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("传输已取消。");write(sync("DATA",n,Arrays.copyOf(buffer,n)));done+=n;progress.update(done,total);}
            write(sync("DONE",(int)(System.currentTimeMillis()/1000),new byte[0]));
            ByteArrayOutputStream response=new ByteArrayOutputStream();int expected=8;
            while(response.size()<expected){byte[] part=readChunk();if(part==null)throw new IOException("设备提前关闭文件传输。");response.write(part);if(response.size()>=8){int length=ByteBuffer.wrap(response.toByteArray(),4,4).order(ByteOrder.LITTLE_ENDIAN).getInt();if(length<0||length>65536)throw new IOException("SYNC 响应长度不正确。");expected=8+length;}}
            byte[] result=response.toByteArray();String tag=new String(result,0,4,StandardCharsets.US_ASCII);
            if(!tag.equals("OKAY"))throw new IOException("文件传输失败："+new String(result,8,result.length-8,StandardCharsets.UTF_8));
        }
        public void close(){try{socket.close();}catch(IOException ignored){}}
    }
    static byte[] sync(String id,int value,byte[] data){ByteBuffer buffer=ByteBuffer.allocate(8+data.length).order(ByteOrder.LITTLE_ENDIAN);buffer.put(id.getBytes(StandardCharsets.US_ASCII)).putInt(value).put(data);return buffer.array();}
    static byte[] exact(InputStream input,int length)throws IOException{byte[] result=new byte[length];int offset=0;while(offset<length){int n=input.read(result,offset,length-offset);if(n<0)throw new EOFException("设备关闭了 ADB 连接。");offset+=n;}return result;}

    public static String shell(Endpoint endpoint,Keys keys,String command,int timeout,Notice notice)throws IOException,GeneralSecurityException{
        try(Connection connection=new Connection(endpoint,keys,notice)){connection.timeout(timeout);connection.open("shell:"+command);return new String(connection.readAll(4*1024*1024),StandardCharsets.UTF_8);}
    }
    public static String friendly(String message){
        if(message==null)return "操作失败，请查看日志。";
        String[][] errors={{"UPDATE_INCOMPATIBLE","签名与已安装版本不同，请使用同一来源的 APK。"},{"VERSION_DOWNGRADE","版本低于设备上的已安装版本，请选择更新的 APK。"},{"NO_MATCHING_ABIS","处理器架构不兼容，请选择与设备处理器架构匹配的版本。"},{"OLDER_SDK","APK 要求更高的 Android 版本。"},{"INSUFFICIENT_STORAGE","设备存储空间不足，请先清理空间。"},{"USER_RESTRICTED","设备限制安装，请检查未知来源设置并确认设备提示。"},{"MISSING_SPLIT","缺少拆分文件，请选齐同一应用的 base 与 split APK，并勾选拆分模式。"}};
        for(String[] error:errors)if(message.contains("INSTALL_FAILED_"+error[0]))return error[1];
        if(message.toLowerCase(Locale.ROOT).contains("timed out"))return "连接或操作超时，请确认设备已开机、授权已允许、IP 正确且网络没有客户端隔离。";
        if(message.toLowerCase(Locale.ROOT).contains("refused"))return "设备没有开放此 ADB 端口，请检查调试设置。";
        return message;
    }
}
