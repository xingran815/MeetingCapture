import Foundation

/// The folder that holds `.config/MeetingCapture`. `NSHomeDirectory()` ignores
/// `$HOME`, so a run of the binary in a test reached the real config, keys and
/// usage count, and once sent an invented transcript to a saved API profile.
/// `MEETINGCAPTURE_HOME` (an absolute path) replaces it, but only together with
/// `MEETINGCAPTURE_E2E=1`, like the other test-only switches.
enum AppHome {
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if environment["MEETINGCAPTURE_E2E"] == "1", let home = environment["MEETINGCAPTURE_HOME"],
            home.hasPrefix("/")
        {
            return URL(fileURLWithPath: home)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
