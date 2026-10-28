import SwiftUI

private struct PushedDetailKey: EnvironmentKey {
    static let defaultValue = false
}

/// 导航只按业务 ID 比较身份；快照保留完整数据，避免要求所有详情模型都实现 Hashable。
private struct NavigationSnapshot<Item: Identifiable>: Hashable {
    let item: Item

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }
}

extension EnvironmentValues {
    /// 详情复用导航栈；编辑事务弹窗必须重置此值，避免继承父页的 push 状态。
    var isPushedDetail: Bool {
        get { self[PushedDetailKey.self] }
        set { self[PushedDetailKey.self] = newValue }
    }
}

/// 仅模态表单创建自己的导航栈，普通详情沿用主导航。
struct DetailNavigationContainer<Content: View>: View {
    @Environment(\.isPushedDetail) private var isPushed
    @ViewBuilder var content: () -> Content

    var body: some View {
        if isPushed {
            content()
        } else {
            NavigationStack { content() }
        }
    }
}

extension View {
    /// 页面退出时清理原有呈现状态，保留调用方的取消和刷新回调。
    func appPush<Destination: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Destination
    ) -> some View {
        navigationDestination(isPresented: isPresented) {
            content().appDetailDestination()
        }
        .onChange(of: isPresented.wrappedValue) { oldValue, newValue in
            if oldValue && !newValue { onDismiss?() }
        }
    }

    func appPush<Item: Identifiable, Destination: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Destination
    ) -> some View {
        navigationDestination(
            item: Binding(
                get: { item.wrappedValue.map { NavigationSnapshot(item: $0) } },
                set: { item.wrappedValue = $0?.item }
            )
        ) { value in
            // 使用系统 item 导航保留出栈中的页面快照，避免绑定清空后详情变成空白。
            content(value.item).appDetailDestination()
        }
        .onChange(of: item.wrappedValue?.id) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                onDismiss?()
            }
        }
    }

    /// 简单值路由与模型路由采用相同的系统转场，退出时由导航栈释放页面快照。
    func appPush<Value: Hashable, Destination: View>(
        value: Binding<Value?>,
        @ViewBuilder content: @escaping (Value) -> Destination
    ) -> some View {
        navigationDestination(item: value) { selected in
            content(selected).appDetailDestination()
        }
    }

    /// 所有 push 入口共用页面与 Tab 栏的导航边界，包括直接使用 NavigationLink 的入口。
    func appDetailDestination() -> some View {
        environment(\.isPushedDetail, true)
            .modifier(NavigationChromeModifier(hidesTabBar: true))
    }

    /// 导入、凭据编辑和系统分享等有独立完成/取消语义的事务仍使用弹窗。
    func appModal<Destination: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Destination
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().environment(\.isPushedDetail, false)
        }
    }

    func appModal<Item: Identifiable, Destination: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Destination
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).environment(\.isPushedDetail, false)
        }
    }
}

/// 每个 Tab 拥有独立导航上下文，标题栏直接归属当前根页。
struct AppTabNavigationStack<Content: View>: View {
    @Environment(AppRouter.self) private var router
    let tab: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .modifier(NavigationChromeModifier(hidesTabBar: false))
                .appPush(
                    item: Binding(
                        get: { router.tab == tab ? router.sheet : nil },
                        set: { value in
                            if router.tab == tab { router.sheet = value }
                        }
                    )
                ) { destination in
                    ManagementDestinationView(destination: destination)
                }
        }
    }
}
