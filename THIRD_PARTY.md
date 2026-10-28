# 第三方来源与许可

项目自有 Swift/Java/Python/脚本源码及原创资源采用根目录 [MIT](LICENSE)。
第三方文件不因根目录许可证而改变授权；服务名称和商标仍归相应权利人。

| 项目 | 使用范围 | 版本或来源 | 许可原文 |
|---|---|---|---|
| Simple Icons | 服务品牌 SVG | 16.34.0 | [CC0-1.0](FlowDeck/Resources/IconLicenses/SimpleIcons.txt) |
| Lobe Icons | AI 等品牌 SVG | 1.95.1 | [MIT](FlowDeck/Resources/IconLicenses/LobeIcons.txt) |
| flag-icons | 地区 SVG、派生 PNG | 7.5.0 | [MIT](FlowDeck/Resources/IconLicenses/FlagIcons.txt) |
| WebSSH-u60pro | 设备端协议适配与历史部署参考；不含服务二进制 | 源码参考 341ea7d30125adb420f63319e0b457747e87742b | [MIT](FlowDeck/Resources/WebSSHLicense.txt) |
| UFI-TOOLS | 设备端 API 与公开协议签名常量参考；不含 APK | 兼容验证 4.1.5 | [MIT](FlowDeck/Resources/UFIToolsLicense.txt) |
| Mihomo | 远端控制 API；不链接或分发核心 | 历史验证 v1.19.32，后续版本需独立验证 | [GPL-3.0](FlowDeck/Resources/MihomoLicense.txt) |

上游：[Simple Icons](https://github.com/simple-icons/simple-icons)、
[Lobe Icons](https://github.com/lobehub/lobe-icons)、[flag-icons](https://github.com/lipis/flag-icons)、
[WebSSH](https://github.com/Jack-bin183/WebSSH-u60pro)、[UFI-TOOLS](https://github.com/kanoqwq/UFI-TOOLS)、
[Mihomo](https://github.com/MetaCubeX/mihomo)。
UFI 许可原文取自提交 `cf83b815efb114ed026f06dc90550845aafbfceb` 的 `LICENCE`；
该提交用于固定许可来源，不声明当前客户端适配了该提交的全部功能。

## 资源修改与出处

图标包来源 URL、模板着色变更见 [Sources.txt](FlowDeck/Resources/IconLicenses/Sources.txt)。
CN 的星形复用节点展开为绝对坐标，保留几何与颜色；TW 展示使用 CN 资源，保留地区身份和请求参数。
PNG 由 `Scripts/render_region_flags.py` 从仓库 SVG 生成。

主 App 图标及 BrandMark 为维护者提供的原创／生成图片，维护者于 2026-10-28 确认拥有使用与再分发权，
同意随项目 MIT 授权；生成源提示和生成平台未归档，不宣称可逐字节重建该图片。
石墨、白瓷替代图标由 `Scripts/render_app_icons.swift` 绘制。
系统 SF Symbols 在运行时使用系统 API，不在仓库中另行分发字体文件。

`F50ConfigBridge.dex` 对应 `Scripts/F50ConfigBridge/*.java`，为本项目源码构建产物，采用 MIT。
重建及校验方法见 [开发指南](docs/Development.md)。

## 不分发的内容

首次安装载荷、第三方核心二进制、ASN/GeoIP/GeoSite 数据库、设备固件、个人订阅、凭据、
设备备份和历史验收截图不属于公开交付物。旧内容仅保留在原私有项目。
若未来重新加入任何安装包或数据集，必须先按精确版本核对分发授权、归属和对应源码义务，
不能仅引用本文件或上游项目首页认定许可已经满足。
