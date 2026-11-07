import Foundation

/// Holds back the mic until system audio starts. The mic starts first, and everything
/// it buffered until then would stay as a permanent lag behind system audio, on both
/// the echo canceller's pairing and the mic track itself.
final class MicStartGate {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.lock()
        isOpen = true
        lock.unlock()
    }

    var passes: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }
}
