import UIKit

/// A separate window also covers full-screen readers and their sheets in app-switcher snapshots.
@MainActor
final class HiddenContentShield {
    private var windows: [String: UIWindow] = [:]

    func cover(_ covered: Bool) {
        guard covered else {
            windows.values.forEach { $0.isHidden = true }
            windows.removeAll()
            return
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.session.role == .windowApplication {
            let id = scene.session.persistentIdentifier
            if windows[id] == nil {
                let controller = UIViewController()
                controller.view.backgroundColor = .systemBackground
                let icon = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
                icon.tintColor = .secondaryLabel
                icon.translatesAutoresizingMaskIntoConstraints = false
                controller.view.addSubview(icon)
                NSLayoutConstraint.activate([
                    icon.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                    icon.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 44),
                    icon.heightAnchor.constraint(equalToConstant: 44),
                ])
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert
                window.rootViewController = controller
                windows[id] = window
            }
            windows[id]?.isHidden = false
        }
    }
}
