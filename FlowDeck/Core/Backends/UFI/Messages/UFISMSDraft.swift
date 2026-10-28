import Foundation

/// 每台设备保留一份本机草稿，只存钥匙串；与设备草稿箱区分，不自动发送或同步。
struct UFISMSDraft: Codable, Equatable {
    var number: String
    var text: String

    static func load(deviceID: String) -> Self? {
        guard let value = KeychainStore.get(account: account(deviceID)),
            let data = value.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(deviceID: String) throws {
        guard number.utf8.count <= 80, text.utf16.count <= 500 else {
            throw ManagementError.invalid("草稿超出支持的长度。")
        }
        let data = try JSONEncoder().encode(self)
        try KeychainStore.setChecked(String(decoding: data, as: UTF8.self), account: Self.account(deviceID))
    }

    static func remove(deviceID: String) throws {
        try KeychainStore.setChecked("", account: account(deviceID))
    }

    private static func account(_ deviceID: String) -> String { "ufi.sms.draft." + deviceID }
}
