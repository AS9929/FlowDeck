import XCTest

@testable import FlowDeck

final class SurgeConverterTests: XCTestCase {
    /// 结构仿照部署用的 Surge 配置，节点和密钥均为测试数据。
    private let surge = """
        [General]
        loglevel = notify

        [Proxy]
        # 注释行
        🇯🇵 [线路A] | 东京一 = ss, 203.0.113.1, 40005, encrypt-method=2022-blake3-aes-128-gcm, password=AAECAwQFBgcICQoLDA0ODw==, tfo=true, udp-relay=true
        🇭🇰 [线路B] | 香港一 = ss, 203.0.113.2, 40006, encrypt-method=aes-128-gcm, password="p,w", udp-relay=false
        🍠 [线路B] | 台北 = ss, 203.0.113.3, 40007, encrypt-method=aes-128-gcm, password=x

        [Proxy Group]
        Proxies = select, include-all-proxies=true, icon-url=https://example.com/Proxy.png
        日本 = select, icon-url=https://example.com/JP.png, include-other-group=Proxies, policy-regex-filter=🇯🇵
        香港 = select, include-other-group=Proxies, policy-regex-filter=🇭🇰
        台湾 = select, include-other-group=Proxies, policy-regex-filter=🍠|台|TW
        美国 = select, include-other-group=Proxies, policy-regex-filter=🇺🇸
        Claude = select, Proxies, 美国, 日本, icon-url=https://example.com/Claude.png
        AdBlock = select, REJECT, Proxies, DIRECT
        Final = select, Proxies, DIRECT

        [Rule]
        RULE-SET,https://raw.githubusercontent.com/a/b/main/custom/direct.list,DIRECT,"update-interval=86400",extended-matching
        RULE-SET,https://raw.githubusercontent.com/a/b/main/claude.list,Claude
        RULE-SET,https://raw.githubusercontent.com/a/b/main/us.list,美国
        RULE-SET,https://raw.githubusercontent.com/a/b/main/reject.list,REJECT-NO-DROP
        RULE-SET,SYSTEM,DIRECT
        FINAL,Final,dns-failed

        [MITM]
        hostname = example.com
        """

    func testConvertMatchesConverterRules() throws {
        let r = try SurgeConverter.convert(surge)
        XCTAssertEqual(r.proxies.count, 3)
        XCTAssertEqual(r.proxies[1].password, "p,w", "引号里的逗号不能被拆开")
        XCTAssertFalse(r.proxies[1].udp)

        let names = r.groups.map(\.name)
        XCTAssertEqual(names, ["Proxies", "自动选择", "日本", "香港", "台湾", "Claude", "AdBlock", "Final"])
        XCTAssertEqual(r.droppedGroups, ["美国"], "没有美国节点时去掉美国组")
        XCTAssertEqual(r.groups[0].members.last, "自动选择")
        XCTAssertEqual(r.groups[0].icon, "https://example.com/Proxy.png")
        XCTAssertEqual(r.groups.first { $0.name == "台湾" }?.members, ["🍠 [线路B] | 台北"])
        XCTAssertEqual(r.groups.first { $0.name == "Claude" }?.members, ["Proxies", "日本"])

        XCTAssertEqual(r.providers.map(\.name), ["custom-direct", "claude", "us", "reject"])
        XCTAssertEqual(r.rules.first, "DOMAIN,captive.apple.com,DIRECT")
        XCTAssertTrue(r.rules.contains("RULE-SET,us,Proxies"), "缺失的地区组回落到 Proxies")
        XCTAssertTrue(r.rules.contains("RULE-SET,reject,REJECT"), "REJECT-NO-DROP 映射为 REJECT")
        XCTAssertEqual(r.rules.last, "MATCH,Final")
        XCTAssertEqual(r.ignoredSections, ["MITM"])
    }

    func testRejectsBadSS2022Key() {
        // 生成 16 字节的虚构输入；AES-256 需要 32 字节，验证长度拒绝路径。
        let invalidKey = Data((0..<16).map { UInt8($0) }).base64EncodedString()
        let bad = "[Proxy]\nA = ss, 1.1.1.1, 1, encrypt-method=2022-blake3-aes-256-gcm, password=\(invalidKey)\n[Rule]\n"
        XCTAssertThrowsError(try SurgeConverter.convert(bad)) { e in
            XCTAssertEqual(e as? SurgeConverter.ConvertError, .badKey("A"))
        }
    }

    func testMergeKeepsDeviceSettingsAndLocalProviders() throws {
        let device = """
            # 来源说明
            mixed-port: 7893
            external-controller: 192.168.0.1:9090
            secret: keep-me
            proxies:
            - name: old
              type: ss
            proxy-groups:
            - name: Proxies
              type: select
              proxies:
              - old
            rule-providers:
              claude:
                type: file
                behavior: classical
                format: text
                path: ./rule_provider/claude.list
            rules:
            - MATCH,Proxies
            dns:
              listen: 0.0.0.0:1053
            ntp:
              enable: true

            """
        let r = try SurgeConverter.convert(surge)
        let (yaml, kept) = try SurgeConverter.merge(r, into: device)
        XCTAssertEqual(kept, ["claude"])
        XCTAssertTrue(yaml.contains("secret: keep-me"))
        XCTAssertTrue(yaml.contains("listen: 0.0.0.0:1053"))
        XCTAssertTrue(yaml.hasPrefix("# 来源说明"))
        XCTAssertFalse(yaml.contains("- name: old"))
        XCTAssertTrue(yaml.contains("path: \"./rule_provider/claude.list\""))
        XCTAssertTrue(yaml.contains("url: \"https://raw.githubusercontent.com/a/b/main/us.list\""))
        XCTAssertTrue(yaml.contains("icon: \"https://example.com/Claude.png\""))
        let order = SurgeConverter.topLevelBlocks(yaml).map(\.key)
        XCTAssertEqual(order, ["", "mixed-port", "external-controller", "secret", "proxies", "proxy-groups", "rule-providers", "rules", "dns", "ntp"])
    }

    func testMergeRefusesUnknownConfig() throws {
        let r = try SurgeConverter.convert(surge)
        XCTAssertThrowsError(try SurgeConverter.merge(r, into: "foo: bar\n"))
    }

    func testQuotingIsJSONCompatible() {
        XCTAssertEqual(SurgeConverter.q("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(SurgeConverter.q("🇯🇵 [x] | y"), "\"🇯🇵 [x] | y\"")
    }
}
