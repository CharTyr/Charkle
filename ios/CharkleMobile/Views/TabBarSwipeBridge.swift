import SwiftUI
import UIKit

/// Non-blocking UIKit gesture bridge that attaches an upward-swipe pan recognizer
/// and active-tab re-tap recognizer strictly to the leading (`素材库`) slot of the
/// enclosing `UITabBarController.tabBar` without disrupting native Liquid Glass
/// tab switching or horizontal scrubbing.
struct LibraryTabBarGestureBridge: UIViewControllerRepresentable {
    let tabCount: Int
    let isLibraryTabActive: Bool
    let onOpenDirectoryAndFilters: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tabCount: tabCount,
            isLibraryTabActive: isLibraryTabActive,
            onOpenDirectoryAndFilters: onOpenDirectoryAndFilters
        )
    }

    func makeUIViewController(context: Context) -> BridgeViewController {
        let vc = BridgeViewController()
        vc.onTabBarFound = { [weak coordinator = context.coordinator] tabBarController in
            coordinator?.attach(to: tabBarController)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: BridgeViewController, context: Context) {
        context.coordinator.tabCount = max(1, tabCount)
        context.coordinator.isLibraryTabActive = isLibraryTabActive
        context.coordinator.onOpenDirectoryAndFilters = onOpenDirectoryAndFilters
        uiViewController.resolveTabBarIfNeeded()
    }

    static func dismantleUIViewController(_ uiViewController: BridgeViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class BridgeViewController: UIViewController {
        var onTabBarFound: ((UITabBarController) -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isHidden = true
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            resolveTabBarIfNeeded()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            resolveTabBarIfNeeded()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            resolveTabBarIfNeeded()
        }

        func resolveTabBarIfNeeded() {
            if let tbc = tabBarController {
                onTabBarFound?(tbc)
                return
            }
            var cursor = parent
            while let vc = cursor {
                if let tbc = vc as? UITabBarController ?? vc.tabBarController {
                    onTabBarFound?(tbc)
                    return
                }
                cursor = vc.parent
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tabCount: Int
        var isLibraryTabActive: Bool
        var onOpenDirectoryAndFilters: () -> Void

        private weak var attachedTabBarController: UITabBarController?
        private weak var attachedTabBar: UITabBar?
        private var swipeUpPan: UIPanGestureRecognizer?
        private var activeRetap: UITapGestureRecognizer?
        private var didTriggerForCurrentPan = false

        init(tabCount: Int, isLibraryTabActive: Bool, onOpenDirectoryAndFilters: @escaping () -> Void) {
            self.tabCount = max(1, tabCount)
            self.isLibraryTabActive = isLibraryTabActive
            self.onOpenDirectoryAndFilters = onOpenDirectoryAndFilters
        }

        private var isLibraryCurrentlySelected: Bool {
            if let tbc = attachedTabBarController {
                return tbc.selectedIndex == 0
            }
            return isLibraryTabActive
        }

        func attach(to tabBarController: UITabBarController) {
            let tabBar = tabBarController.tabBar
            attachedTabBarController = tabBarController
            if attachedTabBar === tabBar { return }
            detach()
            attachedTabBarController = tabBarController
            attachedTabBar = tabBar

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeUpPan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            tabBar.addGestureRecognizer(pan)
            swipeUpPan = pan

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleActiveLibraryRetap(_:)))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tabBar.addGestureRecognizer(tap)
            activeRetap = tap
        }

        func detach() {
            if let tabBar = attachedTabBar {
                if let pan = swipeUpPan { tabBar.removeGestureRecognizer(pan) }
                if let tap = activeRetap { tabBar.removeGestureRecognizer(tap) }
            }
            swipeUpPan = nil
            activeRetap = nil
            attachedTabBar = nil
            attachedTabBarController = nil
        }

        private func isInLibraryTabSlot(point: CGPoint, in tabBar: UITabBar) -> Bool {
            let width = tabBar.bounds.width
            guard width > 0 else { return false }
            let slots = CGFloat(max(tabBar.items?.count ?? tabCount, 1))
            let slotWidth = width / slots
            return point.x >= 0 && point.x <= (slotWidth + 8)
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tabBar = attachedTabBar else { return false }
            let location = touch.location(in: tabBar)
            guard isInLibraryTabSlot(point: location, in: tabBar) else { return false }

            if gestureRecognizer === activeRetap {
                return isLibraryCurrentlySelected
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: - Actions

        @objc private func handleSwipeUpPan(_ recognizer: UIPanGestureRecognizer) {
            guard let tabBar = attachedTabBar else { return }
            switch recognizer.state {
            case .began:
                didTriggerForCurrentPan = false
            case .changed:
                guard !didTriggerForCurrentPan else { return }
                let translation = recognizer.translation(in: tabBar)
                let velocity = recognizer.velocity(in: tabBar)
                let isStronglyUpward = translation.y < 0 && abs(translation.y) > abs(translation.x) * 1.35
                let crossedDistance = translation.y <= -20
                let crossedFlick = translation.y <= -10 && velocity.y <= -240
                if isStronglyUpward && (crossedDistance || crossedFlick) {
                    didTriggerForCurrentPan = true
                    MobileHaptics.light()
                    onOpenDirectoryAndFilters()
                }
            case .ended, .cancelled, .failed:
                didTriggerForCurrentPan = false
            default:
                break
            }
        }

        @objc private func handleActiveLibraryRetap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !didTriggerForCurrentPan, isLibraryCurrentlySelected else { return }
            MobileHaptics.light()
            onOpenDirectoryAndFilters()
        }
    }
}
