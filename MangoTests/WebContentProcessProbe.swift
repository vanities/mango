import Darwin
import WebKit
import XCTest

/// Fault injection for our own simulator WKWebView only; never included in the app.
@MainActor
enum WebContentProcessProbe {
    enum Failure: Error { case unavailableIdentifier, unsafeIdentifier, signalFailed(Int32) }

    static func terminate(_ web: WKWebView) async throws -> Int {
#if targetEnvironment(simulator)
        _ = try await web.evaluateJavaScript("document.readyState")
        guard web.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let identifier = web.value(forKey: "_webProcessIdentifier") as? Int else {
            throw Failure.unavailableIdentifier
        }
        guard identifier > 1, identifier != Int(getpid()) else { throw Failure.unsafeIdentifier }
        // The private kill request can leave the original process alive. Signal only the
        // PID just obtained from this test's WKWebView, without yielding between checks.
        guard Darwin.kill(pid_t(identifier), 0) == 0 else { throw Failure.signalFailed(errno) }
        guard (web.value(forKey: "_webProcessIdentifier") as? Int) == identifier else {
            throw Failure.unsafeIdentifier
        }
        guard Darwin.kill(pid_t(identifier), SIGKILL) == 0 else { throw Failure.signalFailed(errno) }
        return identifier
#else
        throw XCTSkip("The process-termination probe is confined to simulators")
#endif
    }

    static func hasExited(_ identifier: Int) -> Bool {
        identifier > 1 && Darwin.kill(pid_t(identifier), 0) == -1 && errno == ESRCH
    }
}
