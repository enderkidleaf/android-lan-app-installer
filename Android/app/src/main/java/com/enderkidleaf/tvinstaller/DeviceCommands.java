package com.enderkidleaf.tvinstaller;
import java.io.IOException;
import java.util.*;
public final class DeviceCommands {
    private DeviceCommands(){}
    public static String pkg(String value)throws IOException {if(!value.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+"))throw new IOException("设备返回了无效的应用包名。");return value;}
    public static List<String> packages(String output){TreeSet<String> result=new TreeSet<>();for(String line:output.split("\n")){line=line.trim();if(line.startsWith("package:"))try{result.add(pkg(line.substring(8)));}catch(IOException ignored){}}return new ArrayList<>(result);}
    public static String component(String output){for(String line:output.split("\n")){line=line.trim();if(line.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+"))return line;}return null;}
    public static final String[][] KEYS={{"上","KEYCODE_DPAD_UP"},{"左","KEYCODE_DPAD_LEFT"},{"确认","KEYCODE_DPAD_CENTER"},{"右","KEYCODE_DPAD_RIGHT"},{"下","KEYCODE_DPAD_DOWN"},{"返回","KEYCODE_BACK"},{"主页","KEYCODE_HOME"},{"音量 −","KEYCODE_VOLUME_DOWN"},{"音量 +","KEYCODE_VOLUME_UP"}};
    public static String key(String code)throws IOException {for(String[] key:KEYS)if(key[1].equals(code))return "input keyevent "+code;throw new IOException("不支持的遥控按键。");}
    public static String wrapped(String command){return command+"; result=$?; printf '\\n__TOOLS_EXIT:%s\\n' \"$result\"";}
    public static String checked(String output)throws IOException {int index=output.lastIndexOf("\n__TOOLS_EXIT:");if(index<0||!output.substring(index+14).trim().equals("0"))throw new IOException(output.trim().isEmpty()?"设备没有确认操作成功。":output.trim());String text=output.substring(0,index).trim();for(String line:text.split("\n"))if(line.startsWith("Error:")||line.startsWith("Exception")||line.startsWith("Failure"))throw new IOException(text);return text;}
    public static boolean validPng(byte[] data){byte[] signature={(byte)137,80,78,71,13,10,26,10};if(data.length<=24)return false;for(int i=0;i<8;i++)if(data[i]!=signature[i])return false;return true;}
}
