import SwiftUI

/// 缓存按目的拆开，清理请求成功不等于具体网站故障已经修复。
struct ProxyCacheView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(PolicyStore.self) private var policy
    @Environment(ManagementStore.self) private var manager
    @State private var pending: ProxyCacheKind?
    @State private var started = false

    var body: some View {
        DetailSheet(title: "缓存管理", closeDisabled: manager.working) {
            DeviceDetailSummary(symbol: "arrow.triangle.2.circlepath", title: "重新建立解析结果", subtitle: "仅在遇到域名解析或地址映射异常时使用。清理不会修改订阅、分流规则或配置文件。")
            ForEach(ProxyCacheKind.allCases) { kind in
                GlassSection(kind.title) {
                    Text(kind.detail).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Button {
                        pending = kind
                    } label: {
                        Label("清理 " + kind.title, systemImage: kind.symbol)
                    }
                    .disabled(devices.readOnly || manager.working)
                }
            }
            if started { ManagementProgress() }
        }
        .confirmationDialog("清理当前设备的缓存？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let pending { Button("清理 " + pending.title) { clear(pending) } }
        } message: {
            Text(pending?.detail ?? "")
        }
    }

    private func clear(_ kind: ProxyCacheKind) {
        started = true
        Task {
            await manager.run("清理 " + kind.title) {
                _ = try await manager.verifiedAPI(devices, capability: .mihomo)
                try await policy.client.flushCache(kind)
                await manager.setStage("核心已接受清理请求，请重试原来的访问", progress: 1)
            }
        }
    }
}
