import Foundation

/// 同一硬件的所有连接记录共享恢复数据；最后一条记录移除时才清理。
/// 清理失败必须保留设备记录供用户重试，不将部分清理报告为成功。
enum DeviceLocalData {
    static func removeShared(storageID: String, defaults: UserDefaults) throws {
        try WifiRecovery.clear(storageID)
        try UFIWifiRecovery.clear(storageID)
        try UFIAPNBackup.clear(deviceID: storageID)
        try UFISMSDraft.remove(deviceID: storageID)
        try DeviceSnapshotCache.removeChecked(storageID)
        try ConfigHistory.removeChecked(deviceID: storageID)
        for prefix in ["hiddenGroups.", "favoriteGroups.", "preferredGroup."] {
            defaults.removeObject(forKey: prefix + storageID)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("client.note.\(storageID).") {
            defaults.removeObject(forKey: key)
        }
    }
}
