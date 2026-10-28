import SwiftUI

/// 接入终端与黑名单展示；确认、认证和修改由父级操作流程负责。
struct UFIClientListSection: View {
    let clients: [LANClient]
    let access: UFIClientAccess?
    let accessError: String?
    let busy: Bool
    let readOnly: Bool
    @Binding var query: String
    let onAccess: (UFIClientAccess.Entry, Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UFISearchField(placeholder: "搜索名称、IP 或 MAC", query: $query)
            Text("\(clients.count) 台接入设备").font(.headline)
            let filtered = clients.filter {
                query.isEmpty || [$0.hostname, $0.ip, $0.mac].contains { $0.localizedCaseInsensitiveContains(query) }
            }
            if filtered.isEmpty {
                ContentUnavailableView("没有匹配的接入设备", systemImage: "person.2")
            }
            ForEach(filtered) { client in
                GlassSection {
                    HStack(spacing: 12) {
                        FeatureIcon(symbol: client.interface == "Wi-Fi" ? "wifi" : "cable.connector")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.hostname).font(.headline)
                            Text(client.interface).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    DeviceParameterRow(title: "IP 地址", value: client.ip)
                    DeviceParameterRow(title: "MAC 地址", value: client.mac)
                    if client.interface == "Wi-Fi", access?.canEdit == true {
                        Button("阻止连接", systemImage: "hand.raised", role: .destructive) {
                            onAccess(.init(mac: client.mac, name: client.hostname), true)
                        }.disabled(busy || readOnly)
                    }
                }
                .textSelection(.enabled)
            }
            if let access {
                GlassSection("黑名单") {
                    if access.blocked.isEmpty { Text("没有被阻止的设备").foregroundStyle(.secondary) }
                    ForEach(access.blocked) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.name.isEmpty ? "未命名设备" : entry.name).font(.headline)
                            Text(entry.mac).font(.caption).foregroundStyle(.secondary)
                            Button("解除阻止") {
                                onAccess(entry, false)
                            }.disabled(busy || readOnly || !access.canEdit)
                        }
                    }
                    if !access.canEdit {
                        Text("当前不是黑名单模式，请在原厂网页管理过滤策略。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let accessError { Text(accessError).font(.caption).foregroundStyle(.orange) }
            Text("列表来自原厂接入记录；当前固件未返回信号强度与协商速率。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

}
