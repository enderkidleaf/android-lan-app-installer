# 局域网安卓设备安装助手

通过局域网 ADB 给支持网络 ADB 的安卓设备安装 APK，适用于手机、平板、电视、机顶盒等，不限品牌。提供 macOS、Windows 和安卓客户端。

目标设备需要开启网络 ADB 或受支持的无线调试，并完成调试授权；仅接入同一局域网并不足以连接。APK 必须与目标设备的 Android 版本、CPU 架构和操作方式兼容。

| 客户端 | 系统要求 | 自动发现 | 无线配对 | 批量 / 拆分 APK |
| --- | --- | --- | --- | --- |
| macOS | macOS 13+，Apple Silicon / Intel | TCP 5555 + mDNS | 支持 | 支持 |
| Windows | Windows 10 / 11 x64 | TCP 5555 + mDNS | 支持 | 支持 |
| Android | Android 8+，不限 CPU 架构 | TCP 5555 | 普通 TCP ADB 授权；不支持配对式 TLS | 支持 |

安卓端可从手机或平板直接连接目标设备，不需要 root，不需要电脑。Windows 版内置官方 ADB 和 .NET 运行时，无需额外安装开发工具。

## 下载

源码当前版本为 v1.3.0，新增独立的「已安装」区域。已发布的版本见 [GitHub Releases](https://github.com/enderkidleaf/android-lan-app-installer/releases)。仓库名称已统一为 `android-lan-app-installer`，应用标识与安卓签名保持兼容。旧版本下载包仍保留原来的名称。

在 [GitHub Releases](https://github.com/enderkidleaf/android-lan-app-installer/releases) 选择对应平台的安装包。macOS 包为 `android-lan-app-installer-macOS.zip`；Windows 包为 `android-lan-app-installer-Windows-x64.zip`；安卓为 `android-lan-app-installer-Android.apk`。

新客户端的本地构建产物为 `dist/android-lan-app-installer-Windows-x64.zip` 和 `dist/android-lan-app-installer-Android.apk`。Windows 解压整个目录后运行 `AndroidAppInstaller.exe`，保留旁边的 `Resources` 文件夹；安卓 APK 安装到手机或平板，选择安卓客户端设备上下载好的 APK 发送到目标设备。

Windows 与安卓详细说明分别见 [Windows/README.md](Windows/README.md) 和 [Android/README.md](Android/README.md)。

## 连接前准备教程

三个客户端均内置离线教程：在「选择设备」区域点击「准备教程」／「连接前准备教程」。macOS 侧栏、安卓页面下方和 Windows 日志工具栏也有入口。扫描或安装期间仍可查看。

可选择「手机 / 平板」或「电视 / 机顶盒」，并切换普通网络 ADB、无线调试配对、先用 USB 开启三种路径。教程包含开发者选项、目标设备设置、IP 与端口、调试授权、连接排查及使用后关闭调试的说明。配对路径明确说明安卓客户端暂不支持 TLS。教程展示操作说明，需在目标设备手动完成设置。

教程来源：[Android 开发者选项](https://developer.android.com/studio/debug/dev-options)、[Android ADB](https://developer.android.com/tools/adb)、[小米电视 / Mi Box 官方示例](https://www.mi.com/tw/support/article/KA-17750/)。内容集中在 `Shared/PreparationGuide.json`，三个客户端使用同一份数据。

## 使用

1. 双击 `dist/局域网安卓设备安装助手.app`。支持 macOS 13 及以上，Apple Silicon 和 Intel Mac。
2. 目标设备开启网络 ADB 或无线调试，电脑和目标设备接入同一局域网。macOS 提示本地网络权限时选择允许。
3. 点击「发现设备」，或输入目标设备 IP（默认端口 5555），点击连接。在目标设备上确认调试授权。
4. 选择目标设备，拖入 APK 或点击选择文件，然后点击「开始安装」。
5. 安装成功后在目标设备的应用列表打开。操作日志可以导出。

配对方式：如果目标设备有「无线调试 → 使用配对码配对」，点击「无线配对」，填入配对地址、6 位配对码和连接地址。配对端口和连接端口通常不同，以目标设备显示为准。

默认多个 APK 按独立应用依次安装。若选择同一应用的 base 和 split APK，勾选「拆分 APK」，所有文件会作为一次安装提交。XAPK、APKM、AAB 不支持直接安装。

更新使用 `-r` 保留已有应用数据。工具不自动卸载、不降级、不绕过目标设备安装限制。停止后续安装会等待当前安装结束。

### 待安装与已安装

「添加应用」只保留待安装、失败或已跳过的 APK。每项成功后自动移到下方的「已安装」，显示名称、大小、安装目标和完成时间；安装下一批时不会再次发送此前的成功项。拆分 APK 在整组提交成功后一起移动，整组失败则全部保留以便重试。

「已安装」是本次会话的安装成功记录，不是目标设备的全部应用列表。清空待安装文件不会清除成功记录；「清空记录」只清除显示记录，不会卸载应用或把旧文件重新加入队列。需要再次安装同一 APK 或换设备安装时，可主动重新选择该文件。安卓端成功后释放该 APK 的临时缓存，保留名称、大小和目标等显示信息，原始 APK 不受影响。

## 查找与连接

- 扫描所选 IPv4 网卡的真实子网，最多扫描本机所在的 /24（不超过 253 个其他地址），仅检测 TCP 5555。
- macOS / Windows 同时通过官方 ADB 的 mDNS 查询无线连接服务，以支持动态端口；安卓客户端仅支持普通 TCP ADB，暂不支持配对式 TLS 无线调试。
- 大网络的其他地址、自定义端口或未广播的设备可使用手动 `IP:端口`。
- 仅列出网络 ADB 设备，显示设备返回的真实型号、Android 版本和架构。支持不同品牌和类型的安卓设备，请根据型号与地址确认安装目标。
- 开启 ADB 调试不一定开放网络端口；此工具不能远程开启被固件关闭的服务。某些型号需要目标设备端额外设置或初始 USB 调试。
- 目标设备重启后端口或 IP 可能变化，重新发现或查看目标设备网络设置。
- 超时或不可达时，确认 IP、目标设备电源、访客网络和客户端隔离设置。

## 数据与分发

所有 APK 通过本机 ADB 直接发往所选目标设备，不上传云端，无遥测。日志保存在当前内存会话，只有点击导出才会写出文件。配对码不保存；官方 ADB 会在用户目录管理调试信任密钥。使用已运行的本机 ADB 服务，不会全局断开其他设备或停止 ADB 服务。

macOS 应用为本地构建并使用 ad-hoc 签名，未经过 Apple 公证。分发到其他 Mac 时，系统可能要求通过系统设置 → 隐私与安全性 → 仍要打开确认来源。Windows EXE 未使用商业代码签名。安卓 APK 使用专用的本地 release 密钥签名；该密钥不包含在应用或源码提交中。

## 构建与验证

需要 Xcode Command Line Tools（Swift 6 / macOS SDK）。

```bash
bash Scripts/build.sh
bash Scripts/test.sh
bash Scripts/test-install-queue.sh
```

构建脚本在 `Resources/adb` 缺失时从 Google 官方下载 Platform Tools；正式应用内置 ADB，不需要用户另行安装 Python、Node、Homebrew 或 Android Studio。

连接诊断：

```bash
bash Scripts/prepare-build.sh
swiftc -vfsoverlay .build/swift-overlay.json -swift-version 5 -module-cache-path .build/module-cache Sources/Core.swift Scripts/diagnose.swift -o .build/diagnose
.build/diagnose --scan
```

构建时会下载官方 ADB 及其第三方声明，并生成应用图标；这些生成文件不提交到源码仓库。发布包中的第三方声明见 `局域网安卓设备安装助手.app/Contents/Resources/ADB-NOTICE.txt`。官方参考：[ADB 文档](https://developer.android.com/tools/adb)、[Platform Tools](https://developer.android.com/tools/releases/platform-tools)、[小米电视调试设置（品牌示例）](https://www.mi.com/tw/support/article/KA-17750/)。
