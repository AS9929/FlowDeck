import SwiftUI

/// 展示当前维护流程的进度与结果，不发起设备操作。
struct ManagementProgress: View {
    @Environment(ManagementStore.self) private var manager
    @State private var appearedAt = Date()
    var body: some View {
        if !manager.stage.isEmpty && (manager.working || (manager.completedAt.map { $0 >= appearedAt } ?? false)) {
            if manager.working || manager.error != nil {
                GlassSection {
                    Text(manager.stage).font(.subheadline.weight(.medium))
                    if manager.working { ProgressView(value: manager.progress) }
                    if let error = manager.error {
                        Text(error).font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Label(manager.stage, systemImage: "checkmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}
