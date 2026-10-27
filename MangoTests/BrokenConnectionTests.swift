import Darwin
import XCTest
@testable import Mango

/// Mango left mid-book on 2026-10-26 with no crash report; launchd logged "exited due to
/// SIGPIPE". The NAS connection had dropped while the phone was locked, and the next chapter's
/// read wrote to it. These run inside the app host, so they check the process Mango launches.
final class BrokenConnectionTests: XCTestCase {
    func testTheAppIgnoresSIGPIPE() {
        var current = sigaction()
        XCTAssertEqual(sigaction(SIGPIPE, nil, &current), 0)
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        XCTAssertEqual(handler, unsafeBitCast(SIG_IGN, to: Int.self), "SIGPIPE's default action ends the app")
    }

    /// The write libsmb2 makes, on the kind of connection the phone had: reset by the far end.
    func testWritingToAResetConnectionFailsInsteadOfEndingTheApp() {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withSocketAddress(&address) { XCTAssertEqual(bind(listener, $0, length), 0) }
        XCTAssertEqual(listen(listener, 1), 0)
        withSocketAddress(&address) { XCTAssertEqual(getsockname(listener, $0, &length), 0) }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        withSocketAddress(&address) { XCTAssertEqual(connect(client, $0, length), 0) }
        let server = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(server, 0)

        // Linger 0: closing sends RST, as a dropped NAS connection does.
        var reset = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(setsockopt(server, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)), 0)
        close(server)
        var event = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&event, 1, 2000), 1, "The reset must reach the client before it writes")

        let bytes = [UInt8](repeating: 0, count: 64)
        let written = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        let failure = errno
        XCTAssertEqual(written, -1)
        XCTAssertEqual(failure, EPIPE, "The write fails, and the caller gets the error to recover from")
    }

    private func withSocketAddress(_ address: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>) -> Void) {
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) }
        }
    }
}
