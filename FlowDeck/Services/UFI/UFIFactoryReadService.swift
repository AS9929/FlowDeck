import Foundation

/// F50 原厂读取用例。认证后尝试保存当前会话凭据，失败返回独立警告；附加统计失败保留主列表并返回独立提示。
/// 页面负责展示和分页合并，服务不读写页面状态，也不会自动标记短信已读。
@MainActor
struct UFIFactoryReadService {
    struct ClientsResult {
        let clients: [LANClient]
        let access: UFIClientAccess?
        let accessError: String?
    }

    struct MessagesResult {
        let messages: [SMSMessage]
        let storage: UFISMSStorage?
        let storageError: String?
    }

    let context: DeviceServiceContext
    let password: String

    func authenticate() async throws -> String? {
        let api = try context.service((any UFIWifiService).self)
        try await api.authenticateFactory(password: password)
        return try context.rememberFactoryPasswordWarning(password)
    }

    func clients() async throws -> ClientsResult {
        let api = try context.service((any UFIFactoryService).self)
        let clients = try await api.readClients(password: password)
        try context.validate()
        do {
            let access = try await api.readClientAccess(password: password)
            try context.validate()
            return ClientsResult(clients: clients, access: access, accessError: nil)
        } catch {
            try context.validate()
            return ClientsResult(clients: clients, access: nil, accessError: error.localizedDescription)
        }
    }

    func messages(page: Int, includeStorage: Bool) async throws -> MessagesResult {
        let api = try context.service((any UFIMessagesService).self)
        let messages = try await api.readMessages(page: page, password: password)
        try context.validate()
        guard includeStorage else {
            return MessagesResult(messages: messages, storage: nil, storageError: nil)
        }
        do {
            let storage = try await api.messageStorage(password: password)
            try context.validate()
            return MessagesResult(
                messages: messages, storage: storage,
                storageError: storage.listWarning(loadedCount: messages.count))
        } catch {
            try context.validate()
            return MessagesResult(
                messages: messages, storage: nil,
                storageError: "未能核对设备存储数量，空列表尚不能确认没有短信。请重新读取。")
        }
    }
}
