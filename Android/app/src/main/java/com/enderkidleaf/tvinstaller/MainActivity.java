package com.enderkidleaf.tvinstaller;

import android.app.*;
import android.content.*;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.security.GeneralSecurityException;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;
import java.util.zip.ZipFile;

public class MainActivity extends Activity {
    static final int ORANGE=0xffeb5822,INK=0xff232d32,MUTED=0xff6c757a,BG=0xfff7f7f2, PICK_APK=101, EXPORT_LOG=102;
    final ExecutorService worker=Executors.newSingleThreadExecutor();
    final List<Apk> files=new ArrayList<>(); final List<Apk> installedFiles=new ArrayList<>(); final List<AdbCore.Lan> lans=new ArrayList<>();
    final List<View> lockable=new ArrayList<>(); final StringBuilder log=new StringBuilder();
    EditText address; Spinner networks; LinearLayout deviceViews,fileViews,installedViews; TextView banner,targetLabel; Button install,stop;
    ProgressBar progress; CheckBox split; volatile boolean busy,stopRemaining; AdbCore.Endpoint selected; AdbCore.Keys keys;
    volatile AdbCore.Connection active;
    static final class Apk {final File file;final String name;final long size;String state="待安装",detail="",target="";long installedAt;Apk(File f,String n){file=f;name=n;size=f.length();}}
    interface Work {void run()throws Exception;}

    public void onCreate(Bundle state){
        super.onCreate(state);getWindow().setStatusBarColor(BG);getWindow().setNavigationBarColor(BG);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(BG);
        LinearLayout root=vertical();root.setPadding(dp(20),dp(20),dp(20),dp(24));scroll.addView(root);setContentView(scroll);
        root.setOnApplyWindowInsetsListener((view,insets)->{view.setPadding(dp(20),dp(20)+insets.getSystemWindowInsetTop(),dp(20),dp(24)+insets.getSystemWindowInsetBottom());return insets;});root.requestApplyInsets();
        TextView brand=text("局域网安卓设备安装助手",14,true);brand.setTextColor(ORANGE);root.addView(brand);
        root.addView(text("把喜欢的应用，\n装上设备。",28,true));root.addView(text("手机直接连接设备，无需 root 或电脑。",13,false));space(root,20);
        LinearLayout connection=card();root.addView(connection);
        connection.addView(text("01  选择设备",18,true));connection.addView(text("开启目标设备的网络 ADB，并接入同一局域网。",12,false));connection.addView(button("连接前准备教程",this::preparation,false,false));space(connection,10);
        networks=new Spinner(this);lockable.add(networks);connection.addView(networks);
        connection.addView(button("发现设备",()->runWork(()->discover()),true));
        deviceViews=vertical();connection.addView(deviceViews);
        address=new EditText(this);address.setSingleLine(true);address.setTextSize(14);address.setHint("设备 IP 或 IP:端口（默认 5555）");address.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);connection.addView(address);lockable.add(address);
        LinearLayout connectRow=horizontal();connectRow.addView(button("连接",()->{try{AdbCore.Endpoint endpoint=AdbCore.Endpoint.parse(address.getText().toString());runWork(()->connect(endpoint));}catch(Exception e){notice(e.getMessage(),true);}},false),weight());
        connectRow.addView(button("断开",()->{selected=null;deviceViews.removeAllViews();targetLabel.setText("请先连接设备");notice("已清除所选连接。设备端 ADB 调试需在设备设置中关闭。",false);updateInstall();},false),weight());connection.addView(connectRow);
        connection.addView(text("安卓端支持普通 TCP 网络 ADB。配对式 TLS 无线调试请使用桌面客户端。",11,false));
        connection.addView(button("连接诊断与 ADB 终端",()->{Intent intent=new Intent(this,TroubleshootingActivity.class);intent.putExtra("target",selected==null?address.getText().toString():selected.address());intent.putExtra("output",log.toString());startActivity(intent);},false));
        connection.addView(button("设备应用 · 遥控器 · 截图",()->{if(selected==null){notice("请先连接设备。",true);return;}Intent intent=new Intent(this,DeviceToolsActivity.class);intent.putExtra("target",selected.address());startActivity(intent);},false));
        space(root,16);LinearLayout apk=card();root.addView(apk);apk.addView(text("02  添加应用",18,true));apk.addView(text("APK 从手机直接传到所选设备，不上传云端。",12,false));
        apk.addView(button("选择 APK 文件",this::chooseFiles,true));
        fileViews=vertical();apk.addView(fileViews);
        LinearLayout clearRow=horizontal();clearRow.addView(button("清空文件",()->{for(Apk f:files)f.file.delete();files.clear();renderFiles();},false),weight());clearRow.addView(button("操作日志",this::showLog,false,false),weight());apk.addView(clearRow);
        split=new CheckBox(this);split.setText("拆分 APK（全部文件属于同一应用）");split.setTextSize(12);apk.addView(split);lockable.add(split);
        targetLabel=text("请先连接设备",13,true);apk.addView(targetLabel);
        progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);progress.setProgressTintList(android.content.res.ColorStateList.valueOf(ORANGE));apk.addView(progress,new LinearLayout.LayoutParams(-1,dp(7)));
        install=button("开始安装",()->runWork(this::install),true);apk.addView(install);
        stop=button("停止后续安装",()->{stopRemaining=true;stop.setEnabled(false);notice("当前安装结束后将停止队列。",false);},false,false);stop.setVisibility(View.GONE);apk.addView(stop);
        space(root,16);LinearLayout history=card();root.addView(history);history.addView(text("03  已安装",18,true));history.addView(text("本次会话的成功记录，不会参与后续安装。",12,false));
        installedViews=vertical();history.addView(installedViews);history.addView(button("清空记录",()->{installedFiles.clear();renderInstalled();},false,false));renderInstalled();
        space(root,16);banner=text("准备就绪：先发现设备或输入 IP 连接。",13,false);banner.setPadding(dp(14),dp(12),dp(14),dp(12));banner.setBackground(round(0xffeeeeE8,10));root.addView(banner);
        root.addView(button("连接前准备教程",this::preparation,false,false));root.addView(button("使用帮助",this::help,false,false));root.addView(text("v1.5.0 · Android 8+ · 局域网 ADB",11,false));
        try{lans.addAll(AdbCore.Lan.current());networks.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,lans));}catch(Exception e){notice(e.getMessage(),true);}
        updateInstall();
    }
    int dp(int n){return (int)(n*getResources().getDisplayMetrics().density+0.5f);}
    LinearLayout vertical(){LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);return layout;}
    LinearLayout horizontal(){LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.HORIZONTAL);return layout;}
    LinearLayout.LayoutParams weight(){return new LinearLayout.LayoutParams(0,-2,1);}
    GradientDrawable round(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
    LinearLayout card(){LinearLayout layout=vertical();layout.setPadding(dp(16),dp(16),dp(16),dp(16));layout.setBackground(round(Color.WHITE,18));return layout;}
    TextView text(String value,int size,boolean bold){TextView v=new TextView(this);v.setText(value);v.setTextSize(size);v.setTextColor(bold?INK:MUTED);v.setPadding(0,dp(3),0,dp(6));if(bold)v.setTypeface(null,Typeface.BOLD);return v;}
    void space(LinearLayout layout,int height){View v=new View(this);layout.addView(v,new LinearLayout.LayoutParams(1,dp(height)));}
    Button button(String title,Runnable action,boolean primary){return button(title,action,primary,true);}
    Button button(String title,Runnable action,boolean primary,boolean tracked){Button b=new Button(this);b.setText(title);b.setAllCaps(false);b.setTextSize(13);b.setTextColor(primary?Color.WHITE:INK);b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary?ORANGE:0xfff5f5f0));b.setOnClickListener(v->action.run());if(tracked)lockable.add(b);return b;}
    void ui(Runnable action){runOnUiThread(()->{if(!isFinishing()&&!isDestroyed())action.run();});}
    void queueChange(Runnable action)throws Exception{FutureTask<Void> task=new FutureTask<>(()->{if(!isFinishing()&&!isDestroyed())action.run();return null;});runOnUiThread(task);task.get();}
    void archiveInstalled(List<Apk> completed,AdbCore.Endpoint target)throws Exception{
        queueChange(()->{for(Apk apk:completed)if(files.remove(apk)){apk.target=target.address();apk.installedAt=System.currentTimeMillis();installedFiles.add(apk);apk.file.delete();}renderFiles();renderInstalled();});
    }
    void renderInstalled(){
        installedViews.removeAllViews();if(installedFiles.isEmpty()){installedViews.addView(text("安装成功的 APK 会自动移到这里。",12,false));return;}
        for(int i=installedFiles.size()-1;i>=0;i--){Apk apk=installedFiles.get(i);LinearLayout row=vertical();row.setPadding(0,dp(8),0,dp(8));row.addView(text(apk.name,13,true));TextView status=text(String.format(Locale.ROOT,"%.1f MB · 安装成功",apk.size/1048576.0),11,false);status.setTextColor(0xff2e7d32);row.addView(status);row.addView(text("安装到："+apk.target+" · "+new java.text.SimpleDateFormat("MM-dd HH:mm:ss",Locale.ROOT).format(new Date(apk.installedAt)),11,false));installedViews.addView(row);}
    }
    void notice(String value,boolean error){if(value==null)value="操作失败";final String message=value;ui(()->{banner.setText(message);banner.setTextColor(error?0xffa0471d:MUTED);appendLog(message);});}
    void appendLog(String message){log.append('[').append(new java.text.SimpleDateFormat("HH:mm:ss",Locale.ROOT).format(new Date())).append("] ").append(message).append('\n');if(log.length()>150000)log.delete(0,log.length()-100000);}
    void updateInstall(){install.setEnabled(!busy&&selected!=null&&!files.isEmpty());targetLabel.setText(selected==null?"请先连接设备":"安装到："+selected.address());}
    void setBusy(boolean value){busy=value;for(View v:lockable)v.setEnabled(!value);getWindow().getDecorView().setKeepScreenOn(value);updateInstall();}
    void runWork(Work work){
        if(busy)return;setBusy(true);progress.setProgress(0);
        worker.submit(()->{try{if(keys==null)keys=AdbCore.Keys.load(new File(getFilesDir(),"adb-trust"));work.run();}catch(Exception e){notice(AdbCore.friendly(e.getMessage()),true);}finally{active=null;ui(()->{setBusy(false);stop.setVisibility(View.GONE);});}});
    }
    void discover()throws Exception{
        final AdbCore.Lan lan=(AdbCore.Lan)networks.getSelectedItem();if(lan==null)throw new IOException("未发现可用的 Wi-Fi / 以太网，请连接局域网后重新打开应用。");
        notice("正在扫描 "+lan.toString()+"…",false);
        List<AdbCore.Endpoint> found=AdbCore.discover(lan,(done,total)->ui(()->progress.setProgress(total==0?1000:(int)(done*1000/total))));
        ui(()->{
            for(int i=lockable.size()-1;i>=0;i--)if(lockable.get(i).getParent()==deviceViews)lockable.remove(i);
            deviceViews.removeAllViews();
            for(AdbCore.Endpoint endpoint:found){Button b=button("连接 "+endpoint.address(),()->runWork(()->connect(endpoint)),false);b.setEnabled(false);deviceViews.addView(b);}
        });
        notice(found.isEmpty()?"未发现开放的网络 ADB。请确认设备已开机、调试已开启，或手动输入 IP。":"发现 "+found.size()+" 个 ADB 端口，请点击连接并确认设备型号。",found.isEmpty());
    }
    void connect(AdbCore.Endpoint endpoint)throws Exception{
        notice("连接 "+endpoint.address()+"…",false);String info=shell(endpoint,"getprop ro.product.model; getprop ro.build.version.release; getprop ro.product.cpu.abilist",30000);
        String[] lines=info.replace("\r","").split("\n");String model=lines.length>0?lines[0].trim():"Android 设备",version=lines.length>1?lines[1].trim():"未知";
        selected=endpoint;ui(()->{address.setText(endpoint.address());deviceViews.removeAllViews();TextView label=text(model+"\n"+endpoint.address()+" · Android "+version,14,true);label.setTextColor(ORANGE);deviceViews.addView(label);updateInstall();});notice("已连接 "+model+"，可以选择 APK 安装。",false);
    }
    String shell(AdbCore.Endpoint endpoint,String command,int timeout)throws Exception{
        AdbCore.Connection connection=new AdbCore.Connection(endpoint,keys,message->notice(message,false));active=connection;
        try{connection.timeout(timeout);connection.open("shell:"+command);return new String(connection.readAll(4*1024*1024),java.nio.charset.StandardCharsets.UTF_8);}finally{connection.close();active=null;}
    }
    void chooseFiles(){Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);intent.setType("*/*");intent.addCategory(Intent.CATEGORY_OPENABLE);intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);startActivityForResult(intent,PICK_APK);}
    protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);if(result!=RESULT_OK||data==null)return;
        if(request==EXPORT_LOG){try(OutputStream out=getContentResolver().openOutputStream(data.getData())){if(out==null)throw new IOException("无法导出日志");out.write(log.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));notice("日志已导出。",false);}catch(Exception e){notice(e.getMessage(),true);}return;}
        if(request!=PICK_APK)return;List<Uri> uris=new ArrayList<>();if(data.getClipData()!=null){for(int i=0;i<data.getClipData().getItemCount();i++)uris.add(data.getClipData().getItemAt(i).getUri());}else if(data.getData()!=null)uris.add(data.getData());
        runWork(()->{for(Uri uri:uris){try{Apk apk=copyApk(uri);queueChange(()->files.add(apk));}catch(Exception e){notice(e.getMessage(),true);}}ui(this::renderFiles);});
    }
    Apk copyApk(Uri uri)throws IOException{
        String name="应用.apk";long knownSize=-1;
        try(Cursor c=getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE},null,null,null)){if(c!=null&&c.moveToFirst()){int n=c.getColumnIndex(OpenableColumns.DISPLAY_NAME),s=c.getColumnIndex(OpenableColumns.SIZE);if(n>=0)name=c.getString(n);if(s>=0&&!c.isNull(s))knownSize=c.getLong(s);}}
        if(name==null||!name.toLowerCase(Locale.ROOT).endsWith(".apk"))throw new IOException("请选择 .apk 文件；XAPK、APKM、AAB 不能直接安装。");
        if(knownSize>getCacheDir().getUsableSpace()-16*1024*1024)throw new IOException("手机缓存空间不足，请先清理空间。");
        File destination=new File(getCacheDir(),"install-"+UUID.randomUUID()+".apk");
        try{
            try(InputStream in=getContentResolver().openInputStream(uri);OutputStream out=new FileOutputStream(destination)){
                if(in==null)throw new IOException("无法读取 "+name);byte[] buffer=new byte[64*1024];int n;long total=0;
                while((n=in.read(buffer))!=-1){total+=n;if(total>1024L*1024*1024)throw new IOException("单个 APK 不能超过 1 GB。");out.write(buffer,0,n);}
            }
            try(ZipFile zip=new ZipFile(destination)){if(zip.getEntry("AndroidManifest.xml")==null)throw new IOException(name+" 不是有效的 APK：缺少 AndroidManifest.xml。");}
            return new Apk(destination,name);
        }catch(IOException e){destination.delete();throw e;}
    }
    void renderFiles(){
        fileViews.removeAllViews();for(Apk apk:files){LinearLayout item=vertical();item.setPadding(0,dp(8),0,dp(8));item.addView(text(apk.name,13,true));TextView info=text(String.format(Locale.ROOT,"%.1f MB · %s",apk.size/1048576.0,apk.state),11,false);info.setTextColor(apk.state.equals("安装成功")?0xff2e7d32:apk.state.equals("安装失败")?0xffb3261e:MUTED);item.addView(info);if(!apk.detail.isEmpty())item.addView(text(apk.detail,11,false));fileViews.addView(item);}updateInstall();
    }
    void push(AdbCore.Endpoint endpoint,Apk apk,String remote)throws Exception{
        notice("正在传输："+apk.name,false);AdbCore.Connection connection=new AdbCore.Connection(endpoint,keys,message->notice(message,false));active=connection;
        try(InputStream source=new FileInputStream(apk.file)){connection.push(source,apk.file.length(),remote,(done,total)->ui(()->progress.setProgress(total<=0?0:(int)(done*1000/total))));}finally{connection.close();active=null;}
    }
    void install()throws Exception{
        final AdbCore.Endpoint target=selected;if(target==null||files.isEmpty())return;final boolean splitMode=split.isChecked();List<Apk> snapshot=new ArrayList<>(files);stopRemaining=false;ui(()->{stop.setVisibility(View.VISIBLE);stop.setEnabled(true);});
        for(Apk apk:snapshot){apk.state="待安装";apk.detail="";}ui(this::renderFiles);int success=0,failure=0;
        if(splitMode){
            List<String> remotePaths=new ArrayList<>();String session=null;
            try{
                long size=0;for(Apk apk:snapshot)size+=apk.file.length();String created=shell(target,"pm install-create -r -S "+size,30000);ui(()->appendLog(created));Matcher match=Pattern.compile("Success.*\\[(\\d+)\\]",Pattern.DOTALL).matcher(created);
                if(!match.find())throw new IOException(created);session=match.group(1);
                for(int i=0;i<snapshot.size();i++){
                    if(stopRemaining)throw new IOException("拆分安装已取消，未提交安装会话。");Apk apk=snapshot.get(i);apk.state="安装中";ui(this::renderFiles);String path="/data/local/tmp/tv-installer-"+UUID.randomUUID()+".apk";remotePaths.add(path);push(target,apk,path);
                    String written=shell(target,"pm install-write -S "+apk.file.length()+" "+session+" part_"+i+".apk "+path,60000);ui(()->appendLog(written));if(!written.contains("Success"))throw new IOException(written);
                }
                if(stopRemaining)throw new IOException("拆分安装已取消，未提交安装会话。");String committed=shell(target,"pm install-commit "+session,600000);ui(()->appendLog(committed));if(!success(committed))throw new IOException(committed);session=null;for(Apk apk:snapshot)apk.state="安装成功";success=1;archiveInstalled(snapshot,target);
            }catch(Exception e){failure=1;for(Apk apk:snapshot){apk.state="安装失败";apk.detail=AdbCore.friendly(e.getMessage());}}
            finally{if(session!=null){try{shell(target,"pm install-abandon "+session,15000);}catch(Exception ignored){}}for(String path:remotePaths)cleanup(target,path);ui(this::renderFiles);}
        }else{
            for(Apk apk:snapshot){
                if(stopRemaining)break;String remote="/data/local/tmp/tv-installer-"+UUID.randomUUID()+".apk";apk.state="安装中";ui(this::renderFiles);
                try{push(target,apk,remote);notice("设备正在安装："+apk.name,false);String result=shell(target,"pm install -r "+remote,600000);ui(()->appendLog(result));if(!success(result))throw new IOException(result);apk.state="安装成功";success++;archiveInstalled(Collections.singletonList(apk),target);}
                catch(Exception e){apk.state="安装失败";apk.detail=AdbCore.friendly(e.getMessage());failure++;}
                finally{cleanup(target,remote);ui(this::renderFiles);}
            }
        }
        if(stopRemaining)for(Apk apk:snapshot)if(apk.state.equals("待安装"))apk.state="已跳过";ui(this::renderFiles);notice((stopRemaining?"队列已停止":"安装完成")+"：成功 "+success+" 项，失败 "+failure+" 项。",failure>0);
    }
    static boolean success(String output){for(String line:output.split("\n"))if(line.trim().equals("Success"))return true;return false;}
    void cleanup(AdbCore.Endpoint target,String path){try{shell(target,"rm -f "+path,10000);}catch(Exception e){ui(()->appendLog("临时文件清理未完成："+path));}}
    void showLog(){TextView text=text(log.length()==0?"暂无日志":log.toString(),11,false);text.setTextIsSelectable(true);text.setPadding(dp(16),dp(10),dp(16),dp(10));ScrollView scroll=new ScrollView(this);scroll.addView(text);new AlertDialog.Builder(this).setTitle("操作日志").setView(scroll).setPositiveButton("关闭",null).setNeutralButton("导出",(d,w)->{Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT);intent.setType("text/plain");intent.putExtra(Intent.EXTRA_TITLE,"安卓设备安装日志.txt");startActivityForResult(intent,EXPORT_LOG);}).show();}
    void preparation(){PreparationGuide.show(this);}
    void help(){new AlertDialog.Builder(this).setTitle("使用帮助").setMessage("1. 目标设备开启网络 ADB，手机和设备连接同一局域网。\n2. 发现设备或输入 IP:端口，首次连接需在设备授权此手机。\n3. 选择 APK，确认设备 IP，开始安装。\n\n多个独立 APK 按顺序安装；同一应用的拆分 APK 需要选齐 base 与 split 并勾选拆分模式。\n\n本版本支持普通网络 ADB，通常使用 5555 端口；配对式 TLS 无线调试可使用桌面版本。\n\nAPK 仅从手机传到设备。手机缓存会随清空文件或退出应用清理；原文件不会删除。断开连接不会关闭设备端调试服务。\n\n大网络最多扫描本机所在 /24，其他网段使用手动连接。请选择适合目标设备的 Android 版本、CPU 架构与操作方式的 APK。").setPositiveButton("知道了",null).show();}
    public void onBackPressed(){if(busy)new AlertDialog.Builder(this).setTitle("操作正在进行").setMessage("退出可能中断传输。是否退出？").setNegativeButton("继续操作",null).setPositiveButton("退出",(d,w)->{AdbCore.Connection connection=active;if(connection!=null)connection.close();finish();}).show();else super.onBackPressed();}
    protected void onDestroy(){super.onDestroy();stopRemaining=true;AdbCore.Connection connection=active;if(connection!=null)connection.close();worker.shutdownNow();for(Apk apk:files)apk.file.delete();}
}
