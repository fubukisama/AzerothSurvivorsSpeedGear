# AzerothSurvivorsSpeedGear

[English](README.md) · [发行包](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases)

为 Windows x64 版 Azeroth Survivors 制作的游戏内变速面板。控制界面安装到 `AddOns/AZSSpeedGear`，原生后端随游戏启动加载，无需另开外置控制器。

这是社区开发项目。它由 **Lua 插件与原生 DLL 两部分**组成；只有 Lua 文件不能改变游戏模拟速度。0.1.0 已在本机游戏 0.130.0 中加载并实测正常速度约 x1.00、2 倍约 x2.00；其他倍率和未来版本不构成同等验证。兼容证据与限制见 [兼容说明](docs/COMPATIBILITY.md)。

## 安装

先正常退出游戏，将整个发布包解压到游戏目录以外的可写文件夹。发布包应包含：

```text
AddOns/AZSSpeedGear/
  AZSSpeedGear.toc
  AZSSpeedGear.lua
Native/dwmapi.dll
scripts/Install.ps1
scripts/Uninstall.ps1
```

在 PowerShell 中进入发布包目录，先检查，再安装：

```powershell
.\scripts\Install.ps1 -GamePath 'E:\path\AzerothSurvivors.exe' -CheckOnly
.\scripts\Install.ps1 -GamePath 'E:\path\AzerothSurvivors.exe'
```

`-GamePath` 为必填参数，也可以传入包含游戏 EXE 的目录。`-PackagePath` 可另指定包含 `AddOns` 与 `Native` 的发布包根目录。

安装器会验证游戏是 x64 PE、普通导入表包含 `dwmapi.dll`，并检查游戏已经退出。安装后的布局为：

```text
<游戏目录>/
  AzerothSurvivors.exe
  dwmapi.dll
  benilla-config/
    AddOns/AZSSpeedGear/
    AZSSpeedGear-install.json
    AZSSpeedGear-backups/
```

启动原来的 `AzerothSurvivors.exe`，在 **Options → AddOns** 启用 AZSSpeedGear，再进入游戏。输入 `/azsg` 或 `/speedgear` 显示/隐藏面板，`/azsg 2` 请求 2×，`/azsg stop` 急停回到 1×；隐藏面板不会停止控制。面板提供 0.5×、1×、2×、3×、5×按钮，自定义范围为 0.25–10×。

Lua 面板通过 `SG1` 协议的 `AZSSpeedGearCommand` 自定义 CVar 请求倍率；后端读取游戏的 `benilla-config/config.toml`。初始倍率为 **1×**，控制端失联超过 **8 秒**回到 **1×**。暂停、选卡、离局、联机或无法确认单人模式时，面板请求原速；“请求倍率”与计时实测值分别显示。实际可用状态以当前游戏内面板和日志为准。

控制请求经游戏的配置保存机制传递，通常约一秒后生效；“急停”发送恢复请求，也受这个延迟影响。选卡或暂停结束后恢复本局选择的倍率，新的一局默认 1×。后端失联恢复使用真实时钟，不会因游戏倍速而延长为虚拟八秒。

后端通过独立 `dwmapi.dll` 代理加载，并转发游戏使用的系统 DWM 功能。它与 SurvivorsDragonUi 的 `avrt.dll` 使用不同文件名；安装器不会覆盖 `avrt.dll`、DragonUI、共享 `saved-variables.lua` 或游戏存档。不同文件名并不构成共同运行已验证的证明。

## 更新与兼容

安装新发布包前退出游戏，再运行新包里的安装器。安装器只会更新具有有效安装收据、且当前文件 SHA-256 全部匹配的旧版本；旧插件目录、原生 DLL 和收据会移入独立备份目录。无法证明归属的现有 `dwmapi.dll` 或同名插件目录会导致安装停止。

“自动适配”指后端启动时扫描并验证当前版本所需的模拟等待结构，尽量避免绑定某一个 EXE 哈希。**这不保证未来所有版本都兼容。** 结构未知、扫描结果不唯一或验证失败时保持原速，并在日志记录禁用原因；面板根据实测倍率提示未达到目标速度。不能把任意匹配的地址当作可用变速入口。该机制也不是联网下载或自动更新本项目文件的功能。

## 卸载与恢复

正常退出游戏后运行：

```powershell
.\scripts\Uninstall.ps1 -GamePath 'E:\path\AzerothSurvivors.exe' -CheckOnly
.\scripts\Uninstall.ps1 -GamePath 'E:\path\AzerothSurvivors.exe'
```

卸载器先核对安装收据、受管理文件清单及 SHA-256，再把本插件、原生 DLL 和收据移至 `benilla-config/AZSSpeedGear-backups/uninstall-...`，不直接删除。恢复位置和步骤写入备份中的 `uninstall-recovery.json`。恢复前必须退出游戏、核对保留收据中的哈希，并确认目标位置没有其他 DLL 或新安装；不得覆盖其他模组。运行日志和共享保存变量中的本插件设置会保留。

如果安装或卸载遇到文件丢失、文件被改过、目录中有收据未记录的新文件，脚本会停止并报告具体路径。保留现状和备份，再检查文件归属；不要随意删除安装收据来强行覆盖。

## 使用边界

当前后端目标是本机单人模拟。合作模式、浏览器版、Linux/Wine 以及未知游戏版本的行为须分别验证。倍率提升会让计时、技能、敌人模拟和玩家操作节奏一起改变，也可能增加负载；界面显示的倍率请求不代表已测得的真实倍率。

出现不支持状态、速度与计时不一致或异常时先恢复 1×，正常退出游戏，并保留当时的游戏版本、EXE 哈希及游戏目录里的 `AZSSpeedGear.log`。尚未完成的实机测试不能用构建成功或安装成功替代。

## 源码与构建

源码和许可证完整提供。已复用 AZS Speed Controller 的 MIT 连续时钟设计及 MinHook 1.3.4 的实际源码，归属与完整许可见 [第三方说明](THIRD_PARTY_NOTICES.md)。

安装 Visual C++ x64 工具链和 CMake 后运行 `scripts/Build.ps1`，再运行 `scripts/Package.ps1` 生成独立发布包。`AZSSpeedGearProbe.exe <游戏EXE> --selftest` 可以只读检查当前游戏的定位结果。具体测试证据见 [验证记录](docs/VALIDATION.md)。
