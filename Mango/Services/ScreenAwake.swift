import SwiftUI
import UIKit
import os

/// The only writer of `UIApplication.isIdleTimerDisabled`.
///
/// That flag is one switch for the whole app, and more than one thing needs the screen on: a
/// book open in front of you (while Keep screen awake is on) and a transfer running in the
/// foreground. Each used to write its own answer, so the last writer won. The transfer queue
/// checks itself every time the app becomes active, and with nothing to do it switched the
/// reader's keep-awake off: after a glance at Control Center or a notification, the open page
/// dimmed and locked. Each holder now says whether it wants the screen on, and the flag is on
/// while any of them does.
@MainActor
final class ScreenAwake {
    static let shared = ScreenAwake()

    private(set) var holders: Set<String> = []
    private let apply: @MainActor (Bool) -> Void
    private var observer: (any NSObjectProtocol)?

    var keepsScreenOn: Bool { !holders.isEmpty }

    init(apply: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.apply = apply
        // The flag is UIKit's, and code outside this type can still write it while the app is
        // away, so the holders' answer is written again on the way back.
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
    }

    /// `holder` wants the screen kept on, or no longer does. Holders are independent: one
    /// letting go never turns the screen off under another.
    func hold(_ holder: String, _ keepOn: Bool) {
        let changed = keepOn ? holders.insert(holder).inserted : holders.remove(holder) != nil
        if changed {
            Logger.ui.info("[awake] \(holder, privacy: .public) \(keepOn ? "keeps the screen on" : "lets it sleep"); on=\(self.keepsScreenOn) holders=\(self.holders.count)")
        }
        write()
    }

    func release(_ holder: String) { hold(holder, false) }

    private func write() {
        apply(keepsScreenOn)
    }
}

extension View {
    /// Keeps the screen from dimming while this view is on screen and `enabled` is true.
    func keepsScreenAwake(_ enabled: Bool, as holder: String) -> some View {
        modifier(KeepScreenAwake(enabled: enabled, holder: holder))
    }
}

private struct KeepScreenAwake: ViewModifier {
    let enabled: Bool
    let holder: String
    /// Two readers can be open at once (iPad windows); each holds the screen for itself.
    @State private var id = UUID()
    @State private var isOnScreen = false

    private var key: String { "\(holder):\(id.uuidString.prefix(8))" }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                ScreenAwake.shared.hold(key, enabled)
            }
            .onDisappear {
                isOnScreen = false
                ScreenAwake.shared.release(key)
            }
            // The setting can change from inside the reader.
            .onChange(of: enabled) { _, now in
                if isOnScreen { ScreenAwake.shared.hold(key, now) }
            }
    }
}
