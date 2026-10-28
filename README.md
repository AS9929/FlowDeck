# 驭流 FlowDeck（iOS）

集中管理已部署的中兴随身 Wi-Fi 与 Mihomo。当前版本 **0.4.0 / Build 52**。

工程、Scheme 与主模块统一命名为 `FlowDeck`，测试与小组件使用同名前缀。
公共构建使用独立身份，本机维护者构建可通过忽略的配置文件延续原身份。
签名、App Group 和钥匙串配置方法见 [开发指南](docs/Development.md)。

## 接入与兼容边界

| 接入方式 | 当前验证组合 | 职责 |
|---|---|---|
| WebSSH + Mihomo | 中兴 U60 Pro / MU5250 B28 | 原厂设备管理、系统维护与 Mihomo 管理 |
| UFI-TOOLS + Mihomo | 中兴 F50 / MU300 B09，UFI-TOOLS 4.1.5 | Android/UFI 通道、原厂网页接口与 Mihomo 管理 |

型号、固件、服务布局和摘要由适配器再次校验，安装了同名组件不代表可安全写入。
首次 Root、刷机及部署由电脑完成，App 接入页只管理上述已部署组合。
未添加、未验证和离线状态分别处理；演示需要主动选择，不用示例数据掩盖真实失败。
原厂网页密码、管理口令与 Mihomo Secret 分开存入本机钥匙串。

在 **Mihomo → 策略操作（…）→ 常用策略组** 选择首页关注和快捷切换的策略组。
偏好按设备隔离；自动识别兼容 `Proxies` 或唯一可用组，多组不明确时提示选择。
常用策略的选中节点不代表规则模式下所有连接的实际出口，真实出口仍需独立探测。
移除同一硬件的最后一条连接记录时，会清理本机 Wi-Fi/APN 恢复副本、短信草稿和策略偏好；不会修改路由器。


## 代码结构

```text
FlowDeck/
  App/                    启动、路由、快捷指令与系统入口
  Core/
    Devices/              设备记录、会话、操作锁、注册表与兼容性
    Capabilities/         页面和用例依赖的能力协议
    Backends/WebSSH/       WebSSH 通信、原厂接口与数据模型
    Backends/UFI/          UFI 通信及 WiFi、Messages、Radio、Configuration、Maintenance
    Mihomo/               标准控制 API、模型、流量订阅
    Diagnostics/          DNS、时钟、手机 UDP 探测
    Configuration/        配置转换与差异计算
    Persistence/          钥匙串与原厂加密
    Models/               跨功能管理模型
    Demo/                 明确的演示替身
  Services/               完整业务流程：诊断、备份、更新、恢复、原厂读取与回读
  Features/               页面与本地交互状态；UFI 专属页面位于 Device/UFI
  Design/                 通用布局、玻璃、图标和导航组件
  Preferences/            外观与 App 图标偏好
  Legacy/Deployment/      历史电脑辅助部署实现，保留协议测试；非正式接入入口
  Resources/              图标、桥接 dex 与许可证；不含首次部署载荷
Shared/                   App 与 Widget 共用模型和系统动作
FlowDeckWidget/           小组件与控制扩展
FlowDeckTests/            Architecture、Services、Backends、Diagnostics、Mihomo、Features、Legacy
FlowDeckUITests/          导航、未绑定入口与可选 F50 现场检查
Scripts/F50ConfigBridge/  Android 桥接源码及构建/探测工具
Scripts/Tests/            隔离宿主事务测试与统一入口
DesignResources/          设计源资产
build/                    本机历史构建与验收证据，已忽略，不进入产品 target
```

`project.yml` 是工程配置来源；目录增删后运行 `xcodegen generate`。App/Shared 由目录递归编译，
不要手改生成工程增加重复文件。文件归属清单见 [代码结构](docs/CodeStructure.md)。

## 开发与验证

使用 Xcode 26、XcodeGen（本地验证版本及可选 Android 工具链见 [开发指南](docs/Development.md)）；最低 iOS 17，iOS 26 使用系统 Liquid Glass，旧系统使用材质回退。
以下模拟器名称应替换为本机已安装设备，或改用明确的 simulator ID。

```sh
xcodegen generate
xcodebuild -project FlowDeck.xcodeproj -scheme FlowDeck \
  -destination 'platform=iOS Simulator,name=iPhone 16e' build
xcodebuild -project FlowDeck.xcodeproj -scheme FlowDeck \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:FlowDeckTests test
xcodebuild -project FlowDeck.xcodeproj -scheme FlowDeck \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:FlowDeckUITests/NavigationTransitionTests test
```

修改的 Swift 文件使用已有 `.swift-format`，例如 `xcrun swift-format lint --strict <文件路径>`。
不要为了格式统一重排未修改文件。单元测试会导出实际生产脚本的 fixture；随后运行宿主故障注入：

```sh
python3 Scripts/Tests/run_f50_transactions.py '<模拟器 App 数据容器>/Documents'
```

脚本只操作临时目录，不访问网络或真实设备。`Scripts/F50ConfigBridge/test_probe.sh` 是本机 DNS 报文验证，不发起网络请求。真机凭据不提供时相关测试明确跳过，不算通过；配置写入、升级、重启、
断电恢复与手机热点实际联网需要独立验收。私有凭据不得加入源码、日志或 fixture。

Debug 和 Release 均不携带历史首次部署二进制或离线规则数据库。
F50 原生管理使用的 `F50ConfigBridge.dex` 保留完整 Java 源码和可重复校验脚本。
历史首次部署载荷测试明确跳过，不能作为当前客户端安装能力的证明。

## 后续适配

新增方式依次实现能力协议、客户端、兼容性与写入检查，再在 BackendRegistry 显式注册。
公共 Mihomo 页面继续共享；相同能力优先复用业务服务，协议或交互不同才增加专属页面。
未知 backendID 保留原记录并显示不可用，不回退到 WebSSH；能力目录也不能代替写入身份校验。
具体分层规则见 [代码结构](docs/CodeStructure.md)。

本仓库以 FlowDeck 命名后的代码快照作为首次提交；此前的开发历史与验收资料保留在原私有项目中。
开发与构建不依赖私有技术资料库。

## 许可与参与

自有源码与原创资源采用 [MIT](LICENSE)，第三方内容遵循 [各自许可证](THIRD_PARTY.md)。
欢迎按 [贡献指南](CONTRIBUTING.md) 提交改进；安全问题请阅读 [安全政策](SECURITY.md)。
首次 Root、刷机、设备端服务安装以及 App Store 上架需要独立验证，不属于本仓库的开源验收。
