import LocalAuthentication
import SwiftUI
import os

/// When Mango asks for Face ID (or the passcode) again.
enum LockMode: String, Codable, CaseIterable, Sendable {
    case off
    case immediately
    case afterOneMinute
    case afterFifteenMinutes

    var label: String {
        switch self {
        case .off: "Off"
        case .immediately: "Immediately"
        case .afterOneMinute: "After 1 minute"
        case .afterFifteenMinutes: "After 15 minutes"
        }
    }

    /// How long Mango may sit in the background before it locks.
    var grace: TimeInterval {
        switch self {
        case .off: .infinity
        case .immediately: 0
        case .afterOneMinute: 60
        case .afterFifteenMinutes: 15 * 60
        }
    }
}

/// Face ID to open Mango. Locked at launch when the lock is on, and again when it comes back
/// from the background after the grace period. The app switcher's snapshot is covered too.
@MainActor @Observable
final class AppLock {
    private(set) var isLocked: Bool
    /// Covers the screen while the app isn't active, so the app switcher never shows a page.
    private(set) var isCovered = false
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var authenticating = false

    init(settings: AppSettings) {
        self.settings = settings
        isLocked = settings.lockMode != .off
    }

    /// Pure, for the tests: should coming back now ask for Face ID?
    nonisolated static func shouldLock(mode: LockMode, backgroundedAt: Date?, now: Date) -> Bool {
        guard mode != .off else { return false }
        guard let backgroundedAt else { return true }
        return now.timeIntervalSince(backgroundedAt) >= mode.grace
    }

    func sceneChanged(to phase: ScenePhase) {
        let lockOn = settings.lockMode != .off
        switch phase {
        case .background:
            backgroundedAt = backgroundedAt ?? .now
            isCovered = lockOn
        case .inactive:
            isCovered = lockOn
        case .active:
            if !isLocked, Self.shouldLock(mode: settings.lockMode, backgroundedAt: backgroundedAt, now: .now),
               backgroundedAt != nil {
                isLocked = true
                Logger.ui.info("[lock] locked after \(Date.now.timeIntervalSince(self.backgroundedAt ?? .now), format: .fixed(precision: 0))s away")
            }
            backgroundedAt = nil
            isCovered = false
        @unknown default:
            break
        }
    }

    /// Asks for Face ID, or the device passcode when Face ID isn't set up or fails.
    func unlock(reason: String = "Unlock your library") async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await Self.authenticate(reason: reason) {
            isLocked = false
            Logger.ui.info("[lock] unlocked")
        }
    }

    /// Face ID / passcode for something inside the app (the Hidden list) — true when allowed.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Logger.ui.error("[lock] can't authenticate: \(error?.localizedDescription ?? "no passcode", privacy: .public)")
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            Logger.ui.notice("[lock] authentication declined: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether this device can lock at all — a passcode has to be set.
    static var canLock: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Turning the lock on (or changing it) asks first, so it can't be set on someone else's
    /// behalf and then lock them out.
    func setMode(_ mode: LockMode) async -> Bool {
        guard mode != settings.lockMode else { return true }
        guard await Self.authenticate(reason: mode == .off ? "Turn off the lock" : "Lock Mango with Face ID") else { return false }
        settings.lockMode = mode
        return true
    }
}

/// What a locked Mango shows: nothing of the library, and a way in.
struct LockView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Mango is locked")
                    .font(.title3.weight(.semibold))
                Button("Unlock") { Task { await lock.unlock() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
        .task { await lock.unlock() }
    }
}
