import Foundation

/// 已实测设备组合的写入范围。后端复用不代表新型号或固件自动获得写权限。
/// 服务摘要是安装布局契约的一部分；未知脚本不得自动覆盖或放行。
enum DeviceCompatibility {
    static let u60Model = "MU5250"
    static let f50Model = "MU300"
    static let f50Firmware = "F50_FLYMODEM_ZYV1.0.0B09"
    static let f50ServiceDigest = "e559d31d1578bcea782efd561959e8dd2aadffea05e5fcbf0d401bf36c2031d6"

    static func supportsWebSSHWrite(_ snapshot: DeviceSnapshot) -> Bool {
        snapshot.model == u60Model && snapshot.firmware?.hasSuffix("B28") == true
    }

    static func supportsUFIWrite(_ snapshot: DeviceSnapshot) -> Bool {
        snapshot.model == f50Model && snapshot.firmware == f50Firmware
    }
}
