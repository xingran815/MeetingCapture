import Foundation

// Finding from the code review: the duration timer was never cancelled, so a manual
// stop followed by the timer ran the stop path twice, which could resume the capture
// continuation twice and print a second "Done". This lets exactly one stop through.
//
// Finding from the deep review: keys work before capture is live, so an early Enter
// used the one stop while there was nothing to stop and no one to tell, and the
// recording then hung forever. An early stop now waits here until `arm()`.
final class RecordingStopper {

    private let lock = NSLock()
    private var armed = false
    private var stopWaiting = false
    private var stopped = false
    private var timer: DispatchWorkItem?

    /// Call once capture is live. True if a stop arrived before it, which the caller
    /// must now carry out.
    func arm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        armed = true
        return stopWaiting
    }

    /// True the first time only, once armed. Also cancels the timer.
    func claimStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard armed else {
            stopWaiting = true
            return false
        }
        timer?.cancel()
        timer = nil
        if stopped { return false }
        stopped = true
        return true
    }

    /// Calls `fire` after the delay, unless a stop got there first.
    func startTimer(after seconds: Double, queue: DispatchQueue = .main, fire: @escaping () -> Void) {
        let item = DispatchWorkItem(block: fire)
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { timer = item }
        lock.unlock()
        if !alreadyStopped { queue.asyncAfter(deadline: .now() + seconds, execute: item) }
    }
}

/// Enter stops a recording and Space+Enter pauses it, in both the shell and flag mode.
enum RecordingKeys {

    enum Action: Equatable {
        case pauseToggle
        case stop
    }

    static func action(for input: Data) -> Action {
        input.filter { $0 != 0x0A && $0 != 0x0D } == Data([0x20]) ? .pauseToggle : .stop
    }

    /// Finding from the deep review: in a script, stdin is the script's input, not
    /// someone pressing Enter, so it mustn't stop a recording or get eaten by one.
    static func isInteractive(fileDescriptor: Int32) -> Bool {
        isatty(fileDescriptor) == 1
    }

    @available(macOS 13.0, *)
    static func install(on capture: AudioCapture) {
        guard isInteractive(fileDescriptor: STDIN_FILENO) else { return }
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of input, such as a closed pipe: stop listening rather than spin.
                handle.readabilityHandler = nil
                return
            }
            switch action(for: data) {
            case .pauseToggle: capture.pauseToggle()
            case .stop: capture.manualStop()
            }
        }
    }

    static func remove() {
        FileHandle.standardInput.readabilityHandler = nil
    }
}
