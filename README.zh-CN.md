# AzerothSurvivorsSpeedGear

[English](README.md) · [发行包](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases)

0.7.0 新增可设置的倍率快捷键：默认 **Q 减速、E 加速**，按 0.25、0.5、1、2、3、5、10 倍逐档切换。最低与最高档保持不变，不循环；自定义倍率切换到相邻的较低或较高档。点击面板中的快捷键按钮后按新键即可设置，支持 Ctrl/Alt/Shift 组合；Esc 取消、退格清除，“重置 Q/E”恢复默认。键位随插件配置保存，关闭面板后仍可使用；聊天和本面板输入文字时不触发。

插件使用游戏原生按键分派及独立 `Bindings.xml`。保存游戏键位时会临时剥离插件占用，改绑或离开世界时恢复仍由插件占用的原键位。只有录入快捷键期间才临时捕获键盘，普通查看面板不会吞掉其他按键。

0.6.3 新增低帧率保护：加速时连续三帧的客户端时间间隔超过 250ms，插件会请求恢复 1 倍并显示当前语言提示。恢复后保持 1 倍，由你手动重新选择，避免自动升降速反复切换；单次卡顿不会触发。保护不会移除引擎原有的物理步长上限。

0.6.2 修正整数秒采样导致的倍率误确认，改用原始对局计时及带采样误差的观测区间；新发布版本采用 **GPL-3.0-or-later**，第三方许可声明保留。

为 Windows x64 版 Azeroth Survivors 制作的游戏内变速插件。进入游戏后，点击常驻的“倍速”浮窗按钮即可打开或收起面板；按钮和面板均可自由拖动，并分别记住位置。新安装默认只显示浮窗按钮，已有面板显示偏好会保留。

按钮、面板和提示支持游戏当前的 **14 种语言**：简体中文、英语、日语、韩语、波兰语、捷克语、德语、葡萄牙语、西班牙语、法语、罗马尼亚语、土耳其语、俄语、乌克兰语。语言跟随游戏设置，下次进入世界时自动载入所选语种；无需为插件另外选择语言。

0.6.1 起，插件列表的介绍也按游戏保存的语言选择，名称始终为 **AzerothSurvivorsSpeedGear**。游戏会缓存插件元数据；修改语言后，重启游戏可完整刷新介绍。普通客户端的八种 TOC locale 后缀不能覆盖全部十四种游戏语言，因此原生组件在游戏读取插件清单前同步本插件的 `Notes`，只允许清单内的十四种固定译文。安装收据仍校验其余所有字节；已知介绍变化不会阻止自动更新或卸载。

浮窗会在实测倍率接近目标后显示当前倍率，例如“倍速 ×2”或“倍速 ×0.5”。切换尚未确认时显示省略号；暂停、离局或无法确认生效时撤去成功倍率，避免把请求值当作实际生效值。

这是社区开发项目。它由 **Lua 插件与原生 DLL 两部分**组成；只有 Lua 文件不能改变游戏模拟速度。0.1.0 曾在本机游戏 0.130.0 中加载，当时面板显示约 x1.00、x2.00；这些旧显示值不能替代独立计时、人物或技能验证。兼容证据与限制见 [兼容说明](docs/COMPATIBILITY.md)。

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

插件目录还包含翻译、语言检测和原生语言提示文件，请保留整个目录。

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

启动原来的 `AzerothSurvivors.exe`，在 **Options → AddOns** 启用 AzerothSurvivorsSpeedGear，再进入游戏。输入 `/azsg` 或 `/speedgear` 显示/隐藏面板，`/azsg 2` 请求 2×，`/azsg stop` 急停回到 1×；隐藏面板不会停止控制。面板提供 0.5×、1×、2×、3×、5×按钮，自定义范围为 0.25–10×。

也可以随时点击浮窗按钮调出面板。按住按钮左键拖动，松开时只保存位置，不会误开关面板。关闭大面板后，浮窗入口仍保留。

Lua 面板通过 `SG1` 协议的 `AZSSpeedGearCommand` 自定义 CVar 请求倍率。0.3.0 通过游戏 `ConsoleExec` 查询该 CVar，将控制信息即时送入原生组件的本地标准输出/错误管道；仍保留 `benilla-config/config.toml` 后备通道。初始倍率为 **1×**，控制端失联超过 **8 秒**回到 **1×**。暂停、选卡、离局、联机或无法确认单人模式时，面板请求原速；“请求倍率”与计时实测值分别显示。

即时通道可用时，切换与急停不再等待游戏保存配置。每秒查询一次已设置的 CVar 维持心跳，每五秒刷新配置后备，避免低倍速下反复推迟保存并触发超时。若游戏日志设置或后续更新使即时通道不可用，仍受配置保存延迟影响。原生组件只识别本插件的控制查询，不保存游戏控制台日志。

0.4.0 将指令接收与日志转发分开：每个输出通道使用独立转发线程及 256 KiB 有界队列，启动器或控制台输出阻塞不会堵住切速指令。正常负载下原样转发；日志过载时，可能丢弃已经解析过控制信息的最旧待转发日志字节，并记录计数。这个计数不表示丢失了变速指令。收到有效即时心跳时，配置扫描由每秒十次降为一次；即时心跳缺失则恢复快速后备读取。

面板与 `/azsg status` 显示客户端的发送尝试，不冒充原生回执。后端实际收到的通道、后端设定倍速、心跳年龄、配置读取次数和转发丢字节数写入游戏目录的 `AZSSpeedGear-status.json`。从解压后的发布包运行只读查看器可实时查看：

```powershell
.\scripts\Status.ps1 -GamePath 'E:\path\AzerothSurvivors.exe' -Watch
```

查看器不会启动游戏，报告过期会显示离线。游戏沙箱未开放可靠的原生到 Lua 实时读取接口，因此不能把 `ConsoleExec` 存在显示为“后端已连接”。插件列表及面板名称统一为 **AzerothSurvivorsSpeedGear**，操作提示仍支持 14 种语言。

按钮按新鲜的原始对局计时与真实时间观测确认倍率，并计入整数秒采样误差，不再把两次延迟观测当作准确的秒边界。采样稀疏时需要更长时间；原始计时缺失或冻结时，平滑计时仍在走也不会显示已确认。实际变速先于显示确认；明显偏差、冻结、暂停或新请求会撤销确认。这里估计的是已观测到的对局计时，不代表人物、技能或原生回执已得到验证。复现证据及原生模型限制见 [倍速调查](docs/SPEEDINVESTIGATION.md)。选卡或暂停结束后恢复本局选择的倍率，新的一局默认 1×。失联恢复使用真实时钟，不会因游戏倍速而延长为虚拟八秒。

后端通过独立 `dwmapi.dll` 代理加载，并转发游戏使用的系统 DWM 功能。它与 SurvivorsDragonUi 的 `avrt.dll` 使用不同文件名；安装器不会覆盖 `avrt.dll`、DragonUI、共享 `saved-variables.lua` 或游戏存档。不同文件名并不构成共同运行已验证的证明。

语言同步只读取游戏自己的小型 `language.txt` 设置，生成本插件的 `NativeLocale.lua` 提示。它不读取角色存档，也不修改游戏语言设置。生成文件只允许白名单语言代码；安装器与卸载器会验证其固定格式，其他插件文件仍检查 SHA-256。

## 更新与兼容

**0.6.0 起，直接运行 `AzerothSurvivors.exe` 即会自动检查插件更新。** 原生组件在普通后台线程中启动系统自带的隐藏 PowerShell 助手，不需要另开入口。助手脚本与原生组件内嵌的 SHA-256 对应，缺失或被改动时不执行。

检查与预下载在后台进行，不等待网络结果再启动游戏。本次进程继续使用已加载版本；全部游戏实例正常退出后，助手重新校验并安装，完成后的后续启动使用新版。快速重开可能使安装继续等待。网络失败保留现有版本，后续启动继续尝试。任务按同一游戏目录去重，避免原生触发和旧启动入口重复下载。

更新日志在 `benilla-config/AZSSpeedGear-updates/native-update.log`。本项目不修改游戏入口点，也不覆盖 DragonUI 的 `avrt.dll`。安装替换期间使用只读独占 EXE 文件租约与进程复查，缩小直接重启与文件替换交错的窗口；不修改游戏 EXE 内容。

0.5.0 的独立启动入口仍可用于启动前检查或原生加载不可用时的手动更新：

```powershell
.\scripts\Start.ps1 -GamePath 'E:\path\AzerothSurvivors.exe'
```

入口在启动前检查本项目 GitHub 的最新正式 Release，校验包大小、GitHub 提供的 SHA-256 和完整文件清单，再调用已安装的事务安装器；游戏退出后再次检查，覆盖游戏在运行期间更新 EXE 的情况。游戏运行时不覆盖原生 DLL，不强制结束游戏，旧安装和配置保持备份。网络失败会保留现有安装并明确提示检查未完成。需要跳过联网检查时使用 `-SkipUpdate`。

已有原生扫描仍在每次正常加载时重新定位地址。游戏自身的更新交给游戏，本项目更新流程负责本插件及其匹配信息。检查结果独立记录于 `benilla-config/AZSSpeedGear-updates/update-state.json`。旧入口的 `-SkipUpdate` 会给本次游戏进程传递临时跳过标记，不改变全局环境设置。

GitHub 的独立工作流每六小时读取[官方原生更新清单](https://wow.aethus.pl/exe/latest.json)，发现新 EXE 指纹或扫描器变更后，在临时远端 runner 校验并只读扫描官方 EXE，检查加载所需导入和负向扫描用例。它不运行游戏，也不将游戏文件放入本仓库或 Release。结果写入 [compatibility/windows.json](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/blob/main/compatibility/windows.json)。

报告的 `structural_only` 仅表示检查过的结构仍匹配，不能代表对局行为已验证；没有匹配记录显示 `unknown`，不支持的结构显示 `unsupported`。未来引擎、Lua API 或加载机制发生破坏性变化时，仍需要维护新的适配并发布修复；启动入口可获取后续修复。更新器不会从兼容报告读取地址、执行补丁或跳过原生扫描校验。

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

## 许可证

AzerothSurvivorsSpeedGear 的新发布版本采用 **GPL-3.0-or-later**，即 GNU 通用公共许可证第 3 版或由你选择的任何后续版本。你可以按照这些条款再分发和修改本项目，完整 GPLv3 正文见 [LICENSE](LICENSE)。

AZS Speed Controller、MinHook/HDE 继续保留各自的 MIT、BSD-2-Clause 许可证及版权归属，详见 [第三方说明](THIRD_PARTY_NOTICES.md)。

## 源码与构建

源码和许可证完整提供。已复用 AZS Speed Controller 的 MIT 连续时钟设计及 MinHook 1.3.4 的实际源码，归属与完整许可见 [第三方说明](THIRD_PARTY_NOTICES.md)。

安装 Visual C++ x64 工具链和 CMake 后运行 `scripts/Build.ps1`，再运行 `scripts/Package.ps1` 生成独立发布包。`AZSSpeedGearProbe.exe <游戏EXE> --selftest` 可以只读检查当前游戏的定位结果。具体测试证据见 [验证记录](docs/VALIDATION.md)。
