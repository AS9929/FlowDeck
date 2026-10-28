import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 控制中心入口需解锁并转交 App 执行；开关代理和切换模式先弹出系统确认。扩展不保存或使用设备凭据。
@available(iOS 18.0, *)
struct U60ServiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.max.U60Manager.service") {
            ControlWidgetButton(action: U60DirectActionIntent(action: .toggleProxy)) {
                Label("开关代理", systemImage: "power")
            }
        }
        .displayName("代理开关")
        .description("确认后切换当前设备的代理开关，并回读结果。")
    }
}

@available(iOS 18.0, *)
struct U60DiagnosticsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.max.U60Manager.diagnostics") {
            ControlWidgetButton(action: U60QuickActionIntent(action: .diagnostics)) {
                Label("网络诊断", systemImage: "stethoscope")
            }
        }
        .displayName("网络诊断")
        .description("打开 App 检查管理通道、蜂窝和代理出口。")
    }
}

struct U60RecoveryWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: U60RecoveryAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(context.attributes.name, systemImage: "wifi.router")
                Text(context.isStale ? "状态待更新 · 返回 App 继续检查" : context.state.stage).font(.subheadline)
                ProgressView(value: context.state.progress)
            }
            .padding()
            .widgetURL(AppIdentity.url(for: "recovery"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(AppBrand.name, systemImage: "wifi.router")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text(context.isStale ? "返回 App 继续检查" : context.state.stage).font(.caption)
                        ProgressView(value: context.state.progress)
                    }
                }
            } compactLeading: {
                Image(systemName: "wifi.router")
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
            } minimal: {
                Image(systemName: "wifi.router")
            }
            .widgetURL(AppIdentity.url(for: "recovery"))
        }
    }
}

@available(iOS 18.0, *)
struct U60NextNodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.max.U60Manager.nextNode") {
            ControlWidgetButton(action: U60DirectActionIntent(action: .nextNode)) {
                Label("换节点", systemImage: "arrow.triangle.branch")
            }
        }
        .displayName("切换节点")
        .description("切到当前地区内下一个测速成功的节点。")
    }
}

@available(iOS 18.0, *)
struct U60ModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.max.U60Manager.mode") {
            ControlWidgetButton(action: U60DirectActionIntent(action: .cycleMode)) {
                Label("出站模式", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .displayName("出站模式")
        .description("依次切换规则、全局和直连模式。")
    }
}
