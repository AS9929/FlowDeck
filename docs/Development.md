# 独立构建与验证

## 环境

本地验证版本：Xcode 26.3、XcodeGen 2.46.0、iOS 26.2 Simulator。
最低部署目标 iOS 17。安装 Xcode 与模拟器后运行 `brew install xcodegen`。
普通 iOS 构建无需 Android SDK、真实设备或私有凭据。

```sh
xcodegen generate
xcodebuild -project FlowDeck.xcodeproj -scheme FlowDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

模拟器名称可替换为 `xcrun simctl list devices available` 中的设备。
单元测试需要默认的模拟器 ad-hoc 签名；不要设置 `CODE_SIGNING_ALLOWED=NO`，否则钥匙串测试会失败。

## 签名与数据身份

公共默认值在 `Config/App.xcconfig`，使用 `org.flowdeck.app` 和独立 App Group。
真机编译先复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig`，填写自己的 Team 和 Bundle ID，
在开发者账户启用对应 App Group。该文件已被 Git 忽略，严禁提交证书或设备凭据。
App 与 Widget 的 Info.plist、entitlements 和 Swift 运行时从同一组构建变量取值。

原维护者版本通过本机覆盖保留原有 Bundle ID、App Group、钥匙串 service 和 URL scheme；
这些不是开源默认值。改变 Bundle ID 或签名 Team 不能自动迁移已有 App 的私有数据与钥匙串。
小组件 kind、App Intent 类型和持久化 key 中部分历史标识保持稳定，避免破坏已有快捷指令。

## 回归检查

```sh
python3 Scripts/check_public_release.py
xcodebuild -project FlowDeck.xcodeproj -scheme FlowDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowDeckTests test
```

完整单元测试会导出 `CoreScriptFixtures`、`ServiceScriptFixtures` 和 `JournalFixtures`。
获取模拟器数据容器：`xcrun simctl get_app_container <UDID> <实际 Bundle ID> data`，然后运行：

```sh
python3 Scripts/Tests/run_f50_transactions.py '<数据容器>/Documents'
```

历史首次部署二进制测试因不再分发载荷而跳过；需要现场凭据的测试默认跳过。
这些跳过不构成设备验收。UI 导航回归可使用 `-only-testing:FlowDeckUITests/NavigationTransitionTests`。

## Android 桥接源码

`F50ConfigBridge.dex` 在已认证的 UFI 通道内运行，不在 iPhone 上执行。
重建需要 JDK 17、Android SDK Platform 36.1、Build Tools 36.1.0（SDK 工具遵循其自身条款）：

```sh
sdkmanager 'platforms;android-36.1' 'build-tools;36.1.0'
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
sh Scripts/F50ConfigBridge/build.sh --check
```

脚本固定输入源码顺序，使用 Java 8 字节码和 Android min API 26；`--check` 仅比较，不覆盖产物。
修改 Java 后先无参数重建，再用 `--check` 验证，并同步更新调用端固定 SHA256。
`test_probe.sh` 仅在宿主验证 DNS 报文，不连接设备，可在安装 JDK 17 后运行。

## 资源与发布

国旗重建需要 `brew install librsvg` 后运行 `python3 Scripts/render_region_flags.py`。
替代 App 图标可用 `swift Scripts/render_app_icons.swift` 重建。
主图标来源和第三方授权见 [THIRD_PARTY.md](../THIRD_PARTY.md)。

公开前使用无本机配置的新 clone 跑 Debug 测试、Release 构建及脱敏扫描；
同时扫描所有拟公开的 Git 历史。CI 不是法律审查或真实设备验收。
App Store 分发还需独立检查隐私清单、签名、商店政策和设备服务授权，仓库开源不等于上架通过。
