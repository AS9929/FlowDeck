import XCTest

@testable import FlowDeck

/// 覆盖原厂的两种合法成功响应，以及不能混淆为密码错误的失败类别。
final class FactoryResponseTests: XCTestCase {
    func testBackupAcceptsEmptySuccessfulPayload() throws {
        let data = Data(#"[{"jsonrpc":"2.0","id":1,"result":[0]}]"#.utf8)
        let response = try FactoryClient.decodeResponse(data, statusCode: 200, method: "device_backup_proc")
        XCTAssertTrue(response.raw.isEmpty)
    }

    func testLoginRetainsObjectPayload() throws {
        let data = Data(#"[{"result":[0,{"ubus_rpc_session":"test-session"}]}]"#.utf8)
        let response = try FactoryClient.decodeResponse(data, statusCode: 200, method: "web_login")
        XCTAssertEqual(response.string("ubus_rpc_session"), "test-session")
    }

    func testProtocolErrorsAreNotReportedAsPasswordFailures() {
        for json in [#"[{"result":[3]}]"#, #"[{"result":[0,"invalid"]}]"#, #"[{"error":{"code":-32601}}]"#] {
            XCTAssertThrowsError(try FactoryClient.decodeResponse(Data(json.utf8), statusCode: 200, method: "device_backup_proc")) { error in
                XCTAssertTrue(error.localizedDescription.contains("device_backup_proc"))
                XCTAssertFalse(error.localizedDescription.contains("管理密码"))
            }
        }
        XCTAssertThrowsError(try FactoryClient.decodeResponse(Data(), statusCode: 405, method: "download")) { error in
            XCTAssertTrue(error.localizedDescription.contains("405"))
        }
    }

    func testPermissionAndOperationFailureStillThrow() {
        for json in [#"[{"result":[6]}]"#, #"[{"result":[0,{"result":"failure"}]}]"#] {
            XCTAssertThrowsError(try FactoryClient.decodeResponse(Data(json.utf8), statusCode: 200, method: "device_backup_proc"))
        }
    }

    func testBackupRejectsHTMLAndTruncatedCiphertext() {
        let valid = Data("Salted__".utf8) + Data(repeating: 0, count: 24)
        XCTAssertTrue(FactoryClient.isEncryptedBackup(valid))
        XCTAssertFalse(FactoryClient.isEncryptedBackup(Data(valid.dropLast())))
        XCTAssertFalse(FactoryClient.isEncryptedBackup(Data("<html>login</html>".utf8)))
        XCTAssertFalse(FactoryClient.isEncryptedBackup(Data("Salted__".utf8)))
    }
}
