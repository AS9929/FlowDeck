# 随身 Wi-Fi 前置部署与验收

FlowDeck 连接设备上已经运行的管理服务和 Mihomo。首次刷机及设备端安装在电脑上按机型完成。
已经部署好服务的设备可以直接跳到 [接入与验收](#接入与验收)。

| 机型 | FlowDeck 当前验证的固件与服务 | App 预填端口 |
| :--- | :--- | :--- |
| [中兴 U60 Pro](#中兴-u60-pro) | MU5250，B28，WebSSH + Mihomo | WebSSH `8899`，Mihomo `9090` |
| [中兴 F50](#中兴-f50) | MU300，`F50_FLYMODEM_ZYV1.0.0B09`，UFI-TOOLS 完整版 4.1.5 + Mihomo | UFI-TOOLS `2333`，Mihomo `7788` |

端口以设备实际配置为准。先在原厂后台核对型号和完整固件版本，备份原厂配置及已有的代理配置，确认能恢复。
如果版本不同，先向上游核对硬件与固件分支，确认适配情况后再决定是否升级或刷机。

## 中兴 U60 Pro

### 电脑端部署

1. 确认设备为 **MU5250，B28**，电脑能访问原厂后台，并已通过对应机型支持的方式取得设备端管理权限。
2. 按上游部署适用于 U60 Pro 的 **Linux ARM64 WebSSH-u60pro**，在电脑浏览器打开管理页，完成首次初始化并设置账号和密码。[WebSSH-u60pro 部署说明](https://github.com/Jack-bin183/WebSSH-u60pro#deploy)
3. 按当前设备的部署方案安装并启动 **Linux ARM64 Mihomo**，配置实际使用的策略和节点。确认控制端口允许热点局域网访问，并设置独立的 `secret`。[Mihomo 发布页](https://github.com/MetaCubeX/mihomo/releases) · [控制接口配置](https://wiki.metacubex.one/en/config/general/#external-control-api)

### U60 Pro 验收

- 电脑连接设备热点后，能用刚配置的账号登录 WebSSH，看到当前设备的状态。若调整过管理端口，在 FlowDeck 填实际值。
- iPhone 连接同一热点，添加时选择 **WebSSH + Mihomo**。填 WebSSH 账号与密码，以及 Mihomo 控制端口和 Secret。
- 验证结果同时显示「设备身份 / WebSSH：已验证」和 Mihomo 版本。需要原厂设置备份、PIN 等功能时，另填原厂网页后台密码并确认原厂认证通过。

## 中兴 F50

### 电脑端部署

1. 确认设备为 **MU300**，完整固件版本为 **`F50_FLYMODEM_ZYV1.0.0B09`**。电脑能打开原厂后台，并按上游教程确认设备连接正常。UFI-TOOLS 文档包含一键安装器和手动安装两条路径。[UFI-TOOLS 安装与首次使用](https://github.com/kanoqwq/UFI-TOOLS/blob/http-server-version/User_Doc.md#3-安装与首次使用)
2. 将 **UFI-TOOLS 完整版 4.1.5** 安装到 F50 本机，启动管理服务，从电脑浏览器登录后台并设置自己的管理口令。
3. 按 F50 所用的部署方案在设备上安装并启动 **Android arm64-v8a Mihomo**，核对已加载的配置、控制端口和 `secret`。若自行设置了版本或端口，以服务实际运行配置为准。[Mihomo 发布页](https://github.com/MetaCubeX/mihomo/releases) · [控制接口配置](https://wiki.metacubex.one/en/config/general/#external-control-api)

### F50 验收

- 电脑连到设备热点后，能登录 UFI-TOOLS Web 后台，并读取设备状态。
- iPhone 连接同一热点，添加时选择 **UFI-TOOLS + Mihomo**。填 UFI 管理口令，以及实际的 Mihomo 控制端口和 Secret。
- 验证结果同时显示「设备身份 / UFI-TOOLS：已验证」和 Mihomo 版本。使用原生 Wi-Fi 管理时，另填原厂网页后台密码，确认显示「原厂 Wi-Fi：认证通过，配置可读取」。
- 需要用 FlowDeck 启停代理或维护设备端文件时，还要符合对应功能的固件和服务布局要求。遇到不支持提示时，先在原有管理后台核对安装布局。

## 接入与验收

按实际机型走完上述验收，再执行下面的公共检查。管理后台和 Mihomo 控制端口仅供可信局域网访问，使用独立凭据。

1. **确认管理与代理连接**。iPhone 连设备热点并允许 FlowDeck 访问本地网络。在「我的设备」添加对应接入方式，点击「验证连接」。看到设备身份已验证且显示 Mihomo 版本后保存。只要身份通过，App 也允许保存待修复的连接，看到「Mihomo：连接失败」时仍需检查实际控制端口和 Secret。
2. **读取真实状态**。在总览确认设备名称与当前状态，打开 Mihomo 页面读取策略组和节点。也可以从热点局域网使用 Bearer Secret 请求 `GET /version`，预期 HTTP `200` 且返回版本号。[Mihomo API 文档](https://wiki.metacubex.one/api/#version)
3. **检查实际联网**。从总览进入「网络诊断」，分别查看设备管理、蜂窝网络、代理控制、代理 TCP、DNS 和 UDP。再从连接热点的终端访问一个自己知道预期分流结果的网站，在 Mihomo「连接」页核对命中的规则和出口。诊断标为「未检测」的项目保留待验证状态。
4. **如需验证开机自启**。选一个允许短暂断网的时段重启设备，等热点和蜂窝恢复后，复查管理后台、Mihomo 策略和实际联网。

| 现象 | 先检查 |
| :--- | :--- |
| 电脑能打开原厂后台，FlowDeck 的设备身份验证失败 | iPhone 是否连到同一热点、本地网络权限、所选后端、管理服务地址和口令 |
| 设备身份已验证，Mihomo 连不上 | 核心是否运行、`external-controller` 是否能从局域网访问、填的是控制端口还是代理端口，以及 Secret 是否匹配 |
| 能读策略，终端联网或分流异常 | 蜂窝联网、客户端连接路径、DNS、实际命中的规则与节点，再核对设备端转发配置 |

反馈时附上型号、完整固件、管理服务及 Mihomo 版本和失败的验收项。
分享日志或截图前，请移除密码、Secret、订阅链接和设备标识。[设备适配与反馈](https://github.com/AS9929/FlowDeck/issues)
