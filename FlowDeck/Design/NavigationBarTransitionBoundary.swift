import SwiftUI
import UIKit

/// 只负责当前导航页的 Tab 栏转场，不替换导航代理或侧滑返回手势。
struct NavigationBarTransitionBoundary: UIViewControllerRepresentable {
    let hidesTabBar: Bool

    func makeUIViewController(context: Context) -> BoundaryController {
        BoundaryController(hidesTabBar: hidesTabBar)
    }

    func updateUIViewController(_ controller: BoundaryController, context: Context) {
        controller.configureNavigationOwner()
    }

    final class BoundaryController: UIViewController {
        private let hidesTabBar: Bool

        init(hidesTabBar: Bool) {
            self.hidesTabBar = hidesTabBar
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            configureNavigationOwner()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configureNavigationOwner()
            guard #available(iOS 18.0, *), let tabController = tabBarController else { return }
            // SwiftUI 子控制器的 animated 标记不代表实际 push；仅在可见性变化时触发动画。
            TabBarSlideTransition.apply(
                hidden: hidesTabBar, to: tabController,
                coordinator: navigationController?.transitionCoordinator ?? transitionCoordinator,
                animated: !UIAccessibility.isReduceMotionEnabled
            )
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard #available(iOS 18.0, *), let tabController = tabBarController else { return }
            TabBarSlideTransition.restorePresentation(in: tabController)
        }

        func configureNavigationOwner() {
            var owner: UIViewController = self
            while let parent = owner.parent, !(parent is UINavigationController) {
                owner = parent
            }
            guard owner.parent is UINavigationController else { return }
            // UINavigationController 自动隐藏会抢在自定义动画前发生，必须只保留一个控制方。
            owner.hidesBottomBarWhenPushed = false
        }
    }
}

/// 每个 Tab 控制器保留自己的显示进度，不以 UIKit 在转场中临时改变的隐藏标记为动画起点。
/// 系统始终保留底栏的布局位置；整个周期只使用位移和可见性，不与系统显隐动画交接。
@available(iOS 18.0, *)
@MainActor
private enum TabBarSlideTransition {
    private static let drivers = NSMapTable<UITabBarController, Driver>.weakToStrongObjects()

    static func apply(
        hidden: Bool,
        to controller: UITabBarController,
        coordinator: UIViewControllerTransitionCoordinator?,
        animated: Bool
    ) {
        let driver: Driver
        if let existing = drivers.object(forKey: controller) {
            driver = existing
        } else {
            driver = Driver(controller: controller)
            drivers.setObject(driver, forKey: controller)
        }
        driver.request(hidden: hidden, coordinator: coordinator, animated: animated)
    }

    static func restorePresentation(in controller: UITabBarController) {
        drivers.object(forKey: controller)?.restorePresentation()
    }

    /// 控制器弱引用；DisplayLink 只存在于转场期间，结束时注销以解除 target 持有。
    @MainActor
    private final class Driver: NSObject {
        private weak var controller: UITabBarController?
        private var displayLink: CADisplayLink?
        private var coordinator: UIViewControllerTransitionCoordinator?
        private var targetHidden = false
        private var fraction: CGFloat = 0
        private var startFraction: CGFloat = 0
        private var endFraction: CGFloat = 0
        private var travel: CGFloat = 0
        private var startedAt: CFTimeInterval = 0
        private var duration: CFTimeInterval = 0.42
        private var followsGesture = false
        private var handlesInteractiveTransition = false
        private var preparing = false
        private var generation = 0

        init(controller: UITabBarController) {
            self.controller = controller
        }

        func request(hidden: Bool, coordinator: UIViewControllerTransitionCoordinator?, animated: Bool) {
            // 取消侧滑会再次触发详情的 willAppear，让原手势的收尾决定状态，避免二次启动。
            guard !handlesInteractiveTransition else { return }
            guard targetHidden != hidden else {
                restorePresentation()
                return
            }
            let previousTarget = targetHidden
            targetHidden = hidden
            generation += 1
            let currentGeneration = generation
            stopDisplayLink()
            self.coordinator = coordinator
            startFraction = fraction
            endFraction = hidden ? 1 : 0
            prepareSurface()
            guard animated else {
                finish()
                return
            }
            followsGesture = coordinator?.isInteractive == true
            handlesInteractiveTransition = followsGesture
            startedAt = CACurrentMediaTime()
            duration = 0.42 * Double(max(0.25, abs(endFraction - startFraction)))
            let link = CADisplayLink(target: self, selector: #selector(step))
            displayLink = link
            link.add(to: .main, forMode: .common)
            restorePresentation()
            if followsGesture {
                coordinator?.notifyWhenInteractionChanges { [weak self] context in
                    guard let self, generation == currentGeneration else { return }
                    fraction = startFraction + (endFraction - startFraction) * context.percentComplete
                    startFraction = fraction
                    if context.isCancelled {
                        targetHidden = previousTarget
                        endFraction = previousTarget ? 1 : 0
                    }
                    duration = max(0.12, 0.35 * Double(abs(endFraction - startFraction)))
                    startedAt = CACurrentMediaTime()
                    followsGesture = false
                }
            }
        }

        private func prepareSurface() {
            guard let controller else { return }
            preparing = true
            let bar = controller.tabBar
            UIView.performWithoutAnimation {
                // 系统始终保留底栏布局；只测量它的正常位置，不切换系统显隐或触发安全区重排。
                bar.alpha = 0
                bar.layer.sublayerTransform = CATransform3DIdentity
                controller.view.layoutIfNeeded()
                let container = bar.window ?? controller.view!
                let visibleFrame = bar.convert(bar.bounds, to: container)
                travel = max(container.bounds.maxY - visibleFrame.minY + 16, bar.bounds.height)
                bar.layer.sublayerTransform = CATransform3DMakeTranslation(0, travel * fraction, 0)
                bar.isUserInteractionEnabled = false
            }
            preparing = false
        }

        func restorePresentation() {
            guard !preparing, let bar = controller?.tabBar else { return }
            UIView.performWithoutAnimation {
                // 只移动内容层，不改 UIView.transform：交互式导航会重写 frame，带 transform 的 frame 会累计偏移。
                // 点击区域始终由系统布局管理，移动过程中关闭交互，归位后恢复。
                bar.layer.sublayerTransform = CATransform3DMakeTranslation(0, travel * fraction, 0)
                bar.alpha = fraction >= 1 ? 0 : 1
                bar.isUserInteractionEnabled = !targetHidden && displayLink == nil
                bar.accessibilityElementsHidden = targetHidden
            }
        }

        @objc private func step() {
            guard controller != nil else {
                stopDisplayLink()
                return
            }
            if followsGesture, let coordinator {
                fraction = startFraction + (endFraction - startFraction) * coordinator.percentComplete
            } else {
                let elapsed = min(1, (CACurrentMediaTime() - startedAt) / duration)
                let eased = elapsed * elapsed * (3 - 2 * elapsed)
                fraction = startFraction + (endFraction - startFraction) * CGFloat(eased)
                if elapsed >= 1 {
                    finish()
                    return
                }
            }
            restorePresentation()
        }

        private func finish() {
            fraction = endFraction
            stopDisplayLink()
            handlesInteractiveTransition = false
            followsGesture = false
            coordinator = nil
            // 转场结束也只更新当前栏。不能再调用系统显隐 API，否则 UIKit 会重建玻璃呈现并闪回原位。
            restorePresentation()
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--navigation-audit") {
                    print("NAVIGATION_AUDIT hidden=\(targetHidden) fraction=\(fraction)")
                }
            #endif
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}

/// iOS 17 保留 SwiftUI 的兼容处理；18 以上由原生导航协调器驱动滑动。
struct NavigationChromeModifier: ViewModifier {
    let hidesTabBar: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.background(NavigationBarTransitionBoundary(hidesTabBar: hidesTabBar))
        } else {
            content.toolbar(hidesTabBar ? .hidden : .visible, for: .tabBar)
        }
    }
}
