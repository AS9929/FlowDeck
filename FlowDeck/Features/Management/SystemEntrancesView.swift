import SwiftUI

/// 系统快捷入口说明和预览，不改变设备配置。
struct SystemEntrancesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preview = false
    var body: some View {
        DetailSheet(title: "系统入口") {
            GlassSection("主屏与锁屏") {
                Button("预览小组件") { preview = true }
                Text("长按主屏幕 → 编辑 → 添加小组件 → 驭流。可选设备总览、设备仪表、代理出口；支持小、中、大尺寸；中号和大号可刷新状态，并进入节点选择和代理服务。")
                Text("锁屏长按 → 自定 → 添加小组件，可查看电量和当前出口。")
            }
            GlassSection("控制中心 · iOS 18 及以上") {
                Text("打开控制中心 → 添加控制 → 驭流，可添加代理开关、换节点、出站模式与网络诊断。前三项直接执行，诊断打开 App。")
            }
            GlassSection("快捷指令与 Siri") {
                Text("在快捷指令里搜索驭流：查看状态、切换策略组、设置出站模式、开关代理、运行网络诊断。")
            }
            GlassSection("刷新说明") {
                Text("显示最近一次成功读取的快照，超过 2 分钟标记待刷新。轻点刷新会尝试连接当前设备，iOS 决定后台时间线的实际更新时间。")
            }
            GlassSection("重启实时活动") {
                Text("允许实时活动后，重启流程会在锁屏和灵动岛显示阶段。后台暂停检查时显示最近结果，回到 App 后重新检查。")
            }
        }
        .appPush(isPresented: $preview) { WidgetGalleryView() }
    }
}
