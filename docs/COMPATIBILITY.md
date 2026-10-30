# AZSSpeedGear 兼容说明

## 当前设计与证据边界

本项目面向原生 Windows x64 Azeroth Survivors。Lua AddOn 提供游戏内控制，原生后端负责真实变速。安装器核对 PE 架构和 `dwmapi.dll` 导入，不更改游戏 EXE；这一检查只证明当前引导方式具备加载条件，不能证明全部模拟逻辑兼容。

当前协议是通过自定义 CVar 和 `benilla-config/config.toml` 传输的 `SG1` 控制信息。后端默认 1×，控制信息失联 8 秒恢复 1×。若游戏更新改变 CVar 持久化、配置文件结构、保存时机或插件运行周期，必须重新验证控制通信。

0.2.0 增加独立可拖动浮窗和 14 语言目录。原生组件读取 `%APPDATA%/wenilla-rogue/language.txt` 的白名单代码，原子生成本插件的 `NativeLocale.lua`，下一次进入世界时由 Lua 载入。经典 `GetLocale()` 不能完整表达所有自定义游戏语言，仅在缺少原生提示时作为回退；可用时也会参考已载入 HUD 的语言。若游戏改变语言文件位置/代码格式，需要重新适配。浮窗及面板位置与语言选择分别处理，语言刷新不会重置位置或倍率。

原生文件名为 `dwmapi.dll`，与已安装 SurvivorsDragonUi 的 `avrt.dll` 分开。安装器拒绝覆盖无法通过 AZSSpeedGear 安装收据及 SHA-256 验证的同名 DLL；不尝试 DLL 链式加载，不修改 DragonUI 文件。

## 自动识别的含义

目标是扫描识别当前 EXE 的 **25 ms 本地模拟等待**，并验证唯一性、调用关系和相关指令；不依靠单一游戏 EXE 哈希白名单作为唯一匹配条件。扫描与验证通过后才允许启用相应变速路径。

这只能扩大自动识别的可能范围，不能预先保证任何未来版本。以下变化可能需要维护新适配：

- 编译器、指令序列、模拟线程调度或等待机制改变。
- 原来独立的模拟等待被内联、合并或移除。
- 存在多个含相同常量的等待位置，无法确认正确调用者。
- 原生 DLL 加载策略、DWM 导入或可执行文件架构改变。
- CVar、配置格式或游戏内插件 API 改变。

未知结构应拒绝高倍率并保持 1×；扫描产生候选本身不是成功适配的证据。只缩放时钟可能造成画面、计时与模拟速度分离，应分别测量。

## 状态

本文件先记录实现要求。除非下表列出具体测试日期和结果，不应把任何格子理解为已验证。

| 项目 | 当前记录 |
| --- | --- |
| x64 PE 与 `dwmapi.dll` 普通导入检查 | 本机游戏 EXE 只读检查通过，合成 x86 夹具被拒绝；不构成变速行为验证 |
| 文件复制与安装收据 SHA-256 | 合成夹具中的安装、更新备份和可逆卸载通过；正式安装结果另记 |
| Lua 载入、按钮和 CVar 持久化 | 0.130.0 中文面板、预设、急停、slash 命令与心跳落盘已观察通过 |
| 当前 EXE 的模拟等待自动识别 | 只读 Probe 与实际游戏加载均识别唯一 25ms 调用；时长改变或重复候选均拒绝 |
| 各倍率下实际游戏计时、移动、技能与敌人模拟 | 实测 x1.00 / x2.00；5×已加速并在选卡时回1×；慢速、自定义最大值及完整通关未完成 |
| 控制端失联 8 秒回到 1× | 实际 DLL 在独立模拟测试程序中通过；真实游戏待验证 |
| 与 SurvivorsDragonUi / AZSSpellMeter 共同运行 | 0.130.0 同场加载、三个插件显示与两套本地 DLL 同时加载已观察；不代表所有场景均验证 |
| 合作模式 | 未验证 |
| 浏览器版 | 此原生引导不支持 |
| Linux / Wine | 未验证；发布目标为原生 Windows x64 |
| 尚未发布的游戏版本 | 无法预先保证 |

2026-10-30 的安装脚本夹具还验证了：只读预检不复制文件、拒绝被改过的 DLL、拒绝收据未记录的插件文件、拒绝无收据的现有 `dwmapi.dll`，以及 `avrt.dll`、DragonUI、`config.toml`、`saved-variables.lua` 的哈希保持。夹具没有运行游戏或将原生 DLL 加载到游戏。

## 测试记录要求

每次实机记录应包含：游戏显示版本、完整 EXE SHA-256、AZSSpeedGear 版本、原生扫描状态、实际倍率测量、插件组合、失联恢复和正常退出结果。计时测量以未被后端变速的外部墙钟为基准，并将暂停、选卡和读图时间分开。

安全回退、编译通过、离线测试和实机对局是不同证据。安装器的校验通过不能替代游戏行为验证。

## 参考来源

- [游戏插件 API 镜像](https://github.com/migwynkriid13/SurvivorsDragonUi/blob/main/docs/AzerothSurvivors-Addon-API.md)：对局数据与显示控制 API；没有公开真实模拟倍率接口。
- [完整客户端 API 参考](https://github.com/HejAsh/azeroth-survivors-addon-skill/blob/main/azeroth-survivors-addon/references/client-api.md)：Lua、CVar 和插件环境。
- [AZS Speed Controller 时钟后端](https://github.com/Maidenquinn/AZS-Speed-Controller/blob/main/src/hook.cpp)：外置工具的 Windows 时钟缩放实现。
- [其 chrono 修复](https://github.com/Maidenquinn/AZS-Speed-Controller/blob/main/src/timer_fix.cpp)：完整 EXE 哈希与固定 RVA 校验的适配方式；不能视作本项目或未来版本的验证。
- [DragonUI 原生更新器说明](https://github.com/migwynkriid13/SurvivorsDragonUi/blob/main/updater/README.md)：现有 `avrt.dll` 的职责与同名 DLL 限制。
