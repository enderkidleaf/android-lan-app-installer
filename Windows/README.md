# Windows 客户端

适用于 Windows 10 / 11 x64。下载本地 `dist/android-lan-app-installer-Windows-x64.zip`，解压整个目录，然后双击 `AndroidAppInstaller.exe`。

内置官方 ADB 和 .NET 10 运行时，不需要安装 Python、Java、.NET 或 Android Studio。`Resources/adb` 文件夹必须保留在 EXE 旁边。

## 操作

连接前可点击「选择设备」区域或日志工具栏的「准备教程」。内置离线教程按设备类型和连接方式展示开发者选项、网络 ADB、无线配对、USB 前置步骤、IP 与授权；任务进行时也可打开。

目标设备可以是不同品牌的安卓手机、平板、电视或机顶盒，需要支持并开启相应的网络 ADB。

1. 目标设备开启网络 ADB 或无线调试，与电脑连接同一局域网。
2. 选择网络，点击发现设备；也可以手动输入 `IP:端口`。默认端口为 5555。
3. 在目标设备授权弹窗中允许这台电脑，确认设备型号与地址。
4. 选择或拖入 APK，点击开始安装。多个独立 APK 按顺序安装。
5. 同一应用的 base 和 split 文件需要勾选拆分 APK。无线配对需要目标设备提供配对码页面，配对端口和连接端口分开填写。

使用 `-r` 覆盖更新并保留应用数据，不自动卸载、不强制降级。停止后续安装会等待当前项结束。日志仅保存在当前会话，可以手动导出。

安装成功的文件会移出「添加应用」，进入下方独立的「已安装」区域，不参与下一批安装。失败或未执行的项继续保留。拆分 APK 在整组成功后一起移出。「清空记录」只清除本次会话的显示记录，不卸载目标设备应用。

EXE 未使用商业代码签名，Windows 可能提示来源未知。请确认下载来源为本项目。

## 构建

安装 .NET 10 SDK，再执行：

```powershell
dotnet publish Windows/TVAppInstaller.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:DebugType=None -o dist/windows
```

先将 Google 官方 [Windows Platform Tools](https://developer.android.com/tools/releases/platform-tools) 中的 `adb.exe`、DLL 和 `NOTICE.txt` 放到 `Windows/Resources/adb`。这些依赖不提交到源码仓库。

在 macOS / Linux 上也可交叉编译；`Scripts/build-windows.sh` 自动下载 ADB 并生成 ZIP。项目设置了 `EnableWindowsTargeting`。

核心测试：

```powershell
dotnet run --project CrossPlatformTests/WindowsCoreTests.csproj -c Release
```

目前完成了交叉编译、打包验证和 27 项在 macOS 上执行的核心测试。尚未在真实 Windows 设备上运行界面。Windows 不使用模拟 ADB 协议，连接与安装由内置官方 ADB 执行。

## v1.5.0 连接诊断与终端

未连接时也可从设备区域打开「诊断与终端」。检查端口、授权与命令通道；修复前再次读取所有 ADB 设备，存在其他设备或状态不明时不重启共享服务。终端提供常用排障命令与目标设备的单次 shell 命令，支持实时输出、退出码、停止、复制和导出。60 秒或 256 KB 上限会结束当前命令；自定义命令可能修改设备数据。

## v1.4.0 设备工具

连接设备后可打开设备工具：读取当前用户的应用包名列表并搜索，打开或停止应用；用户应用可在确认后卸载或清除全部数据。系统应用不提供卸载和清除数据。提供方向、确认、返回、主页、音量遥控，以及截图预览和 PNG 保存。工具固定使用打开时所选的目标地址，详情见根目录 README。
