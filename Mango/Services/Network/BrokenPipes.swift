import Darwin
import os

/// A dropped NAS connection has to fail a read, never end the app.
///
/// libsmb2 (inside AMSMB2) writes to its socket with `writev` and never sets `SO_NOSIGPIPE`,
/// so a write to a connection that has been reset raises SIGPIPE, whose default action ends
/// the process on the spot: no exception, no crash report, just the Home Screen. That is how
/// Mango left mid-book on 2026-10-26 (launchd: "exited due to SIGPIPE"). The connection
/// dropped while the phone sat locked, and the next chapter's read sent `NASClient`'s echo
/// into it. Ignored, the write fails with EPIPE, the echo throws, and `ensureConnected`
/// opens a fresh connection.
enum BrokenPipes {
    static func ignore() {
        signal(SIGPIPE, SIG_IGN)
        Logger.nas.info("[nas] SIGPIPE ignored: a dropped connection fails its read instead of ending the app")
    }
}
