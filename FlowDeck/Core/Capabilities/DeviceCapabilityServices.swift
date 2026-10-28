import Foundation

/// 专有数据模型保持原协议边界；页面依赖能力接口，后续可复用同一界面接入不同传输。
protocol UFIWifiService: Sendable {
    func authenticateFactory(password: String) async throws
    func readWifiAccessPoints(password: String) async throws -> [UFIWifiAccessPoint]
    func saveWifiAccessPoint(_ target: UFIWifiAccessPoint, replacing original: UFIWifiAccessPoint, password: String) async throws
    func setWifiBands(_ chips: Set<String>, replacing points: [UFIWifiAccessPoint], password: String) async throws
}

protocol UFIFactoryService: Sendable {
    func factoryDetails(password: String) async throws -> JSONObject
    func readClients(password: String) async throws -> [LANClient]
    func readClientAccess(password: String) async throws -> UFIClientAccess
    func setClientBlocked(mac: String, name: String, blocked: Bool, replacing state: UFIClientAccess, password: String) async throws
    func readAPNs(password: String) async throws -> UFIAPNState
    func saveAPN(_ profile: UFIAPNProfile, replacing state: UFIAPNState, password: String) async throws
    func selectAPN(_ profile: UFIAPNProfile?, from state: UFIAPNState, password: String) async throws
    func deleteAPN(_ profile: UFIAPNProfile, from state: UFIAPNState, password: String) async throws
    func setRoaming(_ enabled: Bool, password: String) async throws
    func setNetworkMode(_ mode: UFINetworkMode, password: String) async throws
    func setUSBProtocol(_ mode: String, password: String) async throws
    func operatePIN(_ operation: UFIPINOperation, pin: String, newPIN: String, puk: String, password: String) async throws
    func performFactoryAction(_ action: UFIFactoryAction, password: String) async throws
}

protocol UFIMessagesService: Sendable {
    func readMessages(page: Int, password: String) async throws -> [SMSMessage]
    func messageStorage(password: String) async throws -> UFISMSStorage
    func sendMessage(number: String, text: String, password: String) async throws
    func deleteMessage(id: Int, password: String) async throws
    func performFactoryAction(_ action: UFIFactoryAction, password: String) async throws
}

protocol UFIDiagnosticsService: Sendable {
    func readClock() async throws -> String
    func synchronizeClock() async throws -> DiagnosticCheck
    func dnsDiagnostic(publicResolver: Bool) async throws -> DiagnosticCheck
}

protocol UFICoreUpdateService: Sendable {
    func coreUpdateState() async throws -> UFICoreState
    func startCoreUpdate(_ release: UFICoreRelease?, package: Data?, progress: @Sendable (Double) async -> Void) async throws
    func recoverCoreUpdate() async throws
}

protocol UFIAppUpdateService: Sendable {
    func serviceUpdateState() async throws -> UFIServiceUpdateState
    func prepareServicePackage(_ data: Data, progress: @Sendable (Double) async -> Void) async throws -> UFIServicePackage
    func installServicePackage(_ package: UFIServicePackage?) async throws
    func recoverServiceUpdate() async throws
}

protocol UFIForwardingService: Sendable {
    func forwardingState(method: UFIForwardingState.Method) async throws -> UFIForwardingState
    func saveForwarding(
        _ values: [String: String], method: UFIForwardingState.Method,
        replacing original: UFIForwardingState) async throws
    func toggleForwarding(
        _ enabled: Bool, method: UFIForwardingState.Method,
        replacing original: UFIForwardingState) async throws
    func saveForwardingFilter(
        _ filter: [String: String], method: UFIForwardingState.Method,
        replacing original: UFIForwardingState) async throws
}

protocol UFIArchiveService: Sendable {
    func captureSettings(password: String) async throws -> UFISettingsArchive
}

/// 汇总页展示多种原厂能力；各编辑页仍只依赖自己的子协议。
protocol UFIDeviceService: WebSSHAPI, UFIWifiService, UFIFactoryService, UFIMessagesService,
    UFIDiagnosticsService, UFIArchiveService, UFIRadioAPI
{
    func hardwareDetails() async throws -> UFIHardwareDetails
}

extension UFIClient: UFIDeviceService, UFICoreUpdateService, UFIAppUpdateService, UFIForwardingService {}
