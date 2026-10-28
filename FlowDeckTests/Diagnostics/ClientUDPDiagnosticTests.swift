import XCTest

@testable import FlowDeck

/// 使用脱敏 STUN 应答验证事务匹配、截断及路由边界，不依赖公网服务稳定性。
final class ClientUDPDiagnosticTests: XCTestCase {
    private let transaction = Array(UInt8(1)...UInt8(12))

    private var response: Data {
        // 203.0.113.4:54321，RFC 8489 XOR-MAPPED-ADDRESS。
        Data(
            [0x01, 0x01, 0, 12] + STUNPacket.cookie + transaction
                + [0, 0x20, 0, 8, 0, 1, 0xf5, 0x23, 0xea, 0x12, 0xd5, 0x46])
    }

    func testBindingRequestAndResponse() {
        let request = STUNPacket.request(transaction: transaction)
        XCTAssertEqual(request.count, 20)
        XCTAssertEqual(Array(request.prefix(8)), [0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42])
        XCTAssertEqual(STUNPacket.address(response: response, transaction: transaction), "203.0.113.4")
    }

    func testRejectsTruncationSpoofedTransactionAndMalformedAttributes() {
        for length in 0..<response.count {
            XCTAssertNil(STUNPacket.address(response: Data(response.prefix(length)), transaction: transaction))
        }
        for index in [0, 1, 2, 3, 4, 8, 22, 23, 24, 25] {
            var bad = response
            bad[index] ^= 0xff
            XCTAssertNil(STUNPacket.address(response: bad, transaction: transaction))
        }
        var missing = response
        missing[21] = 0x21
        XCTAssertNil(STUNPacket.address(response: missing, transaction: transaction))
        var duplicate = response
        duplicate[3] = 24
        duplicate.append(response.suffix(12))
        XCTAssertNil(STUNPacket.address(response: duplicate, transaction: transaction))
    }

    func testValidatesTrailingAttributesAndTheirPadding() {
        var packet = response
        packet[3] = 20
        packet.append(contentsOf: [0x80, 0x22, 0, 1, 65, 0, 0, 0])
        XCTAssertEqual(STUNPacket.address(response: packet, transaction: transaction), "203.0.113.4")
        packet[35] = 9
        XCTAssertNil(STUNPacket.address(response: packet, transaction: transaction))
    }

    func testUnrelatedWifiOrCellularCannotPassAsCurrentDevice() {
        XCTAssertTrue(ClientUDPDiagnostic.matchesGateway(wifi: true, gateways: ["192.168.0.1"], deviceHost: "192.168.0.1"))
        XCTAssertFalse(ClientUDPDiagnostic.matchesGateway(wifi: false, gateways: ["192.168.0.1"], deviceHost: "192.168.0.1"))
        XCTAssertFalse(ClientUDPDiagnostic.matchesGateway(wifi: true, gateways: ["192.168.1.1"], deviceHost: "192.168.0.1"))
        XCTAssertFalse(ClientUDPDiagnostic.matchesGateway(wifi: true, gateways: [], deviceHost: "192.168.0.1"))
        XCTAssertFalse(ClientUDPDiagnostic.matchesGateway(wifi: true, gateways: ["invalid"], deviceHost: "invalid"))
    }

    #if targetEnvironment(simulator)
        func testSimulatorExplainsThatHostNetworkIsNotPhoneWifi() async {
            let result = await ClientUDPDiagnostic.run(deviceHost: "192.168.0.1")
            XCTAssertEqual(result.outcome, .unavailable)
            XCTAssertTrue(result.detail.contains("模拟器使用 Mac 网络"))
            XCTAssertFalse(result.detail.contains("关闭手机 VPN"))
        }
    #endif

    func testInvalidHostNeverStartsProbe() async {
        let result = await ClientUDPDiagnostic.run(deviceHost: "")
        XCTAssertEqual(result.outcome, .unavailable)
    }

    func testCancelledProbeCompletesWithoutHanging() async {
        let task = Task { await ClientUDPDiagnostic.run(deviceHost: "192.168.0.1") }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .unavailable)
    }
}
