import Foundation

/// 未绑定、未知后端或地址损坏的真实会话。直接调用也只能失败，不能泄露旧设备状态。
struct UnavailableClient: WebSSHAPI, MihomoAPI {
    private var failure: ManagementError { .invalid("设备连接不可用，请检查接入方式、地址与凭据。") }
    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        throw failure
    }

    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        throw failure
    }

    func mihomoStatus() async throws -> MihomoServiceStatus {
        throw failure
    }

    func control(_ action: ProxyAction) async throws -> String {
        throw failure
    }

    func setAutostart(_ enabled: Bool) async throws {
        throw failure
    }

    func connectivity() async throws -> Bool {
        throw failure
    }

    func loadConfig() async throws -> String {
        throw failure
    }

    func saveConfig(_ content: String) async throws {
        throw failure
    }

    func checkConfig() async throws -> ConfigCheckResult {
        throw failure
    }

    func dataVersion() async throws -> DataVersion {
        throw failure
    }

    func startDataUpdate() async throws -> DataUpdateStatus {
        throw failure
    }

    func dataUpdateStatus() async throws -> DataUpdateStatus {
        throw failure
    }

    func snapshot() async throws -> DeviceSnapshot {
        throw failure
    }

    func clients() async throws -> [LANClient] {
        throw failure
    }

    func sms() async throws -> [SMSMessage] {
        throw failure
    }

    func markSMSRead(id: Int) async throws {
        throw failure
    }

    func wifiSettings() async throws -> [String: WifiRadioSettings] {
        throw failure
    }

    func setWifi(_ settings: [String: WifiRadioSettings]) async throws {
        throw failure
    }

    func setNetworkMode(_ mode: NetworkMode) async throws {
        throw failure
    }

    func lockLTEBands(_ bands: [Int]) async throws {
        throw failure
    }

    func lockNRBands(_ bands: [Int]) async throws {
        throw failure
    }

    func reboot() async throws {
        throw failure
    }

    func version() async throws -> VersionResponse {
        throw failure
    }

    func proxies() async throws -> [String: MihomoProxy] {
        throw failure
    }

    func select(group: String, proxy: String) async throws {
        throw failure
    }

    func delay(proxy: String, url: String, timeoutMs: Int) async throws -> Int {
        throw failure
    }

    func groupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int] {
        throw failure
    }

    func config() async throws -> MihomoConfig {
        throw failure
    }

    func runtimeSettings() async throws -> JSONObject {
        throw failure
    }

    func patchRuntime(_ change: RuntimeChange) async throws {
        throw failure
    }

    func providers(_ kind: ProviderKind) async throws -> [MihomoProvider] {
        throw failure
    }

    func updateProvider(_ name: String, kind: ProviderKind) async throws {
        throw failure
    }

    func queryDNS(_ name: String, type: String) async throws -> JSONObject {
        throw failure
    }

    func flushCache(_ kind: ProxyCacheKind) async throws {
        throw failure
    }

    func healthCheckProvider(_ name: String) async throws {
        throw failure
    }

    func logs(level: String) -> AsyncThrowingStream<MihomoLog, Error> {
        AsyncThrowingStream { $0.finish(throwing: failure) }
    }

    func setMode(_ mode: OutboundMode) async throws {
        throw failure
    }

    func rules() async throws -> [MihomoRule] {
        throw failure
    }

    func connections() async throws -> ConnectionsResponse {
        throw failure
    }

    func closeConnection(id: String) async throws {
        throw failure
    }

    func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        AsyncThrowingStream { $0.finish(throwing: failure) }
    }

}
