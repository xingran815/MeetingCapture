import Foundation

// Catalog of conferencing apps eligible for SCStream audio auto-detection.
//
// At record time AudioCapture scopes the SCContentFilter to the first *enabled*
// app from this catalog that is actually running. If none are running (or none
// are enabled), capture falls back to ALL system audio. Which entries are
// enabled is user-controlled and persisted in Config.enabledMeetingAppIDs.
//
// Google Meet has no app of its own — it runs inside Chrome/Safari, so capturing
// the browser captures Meet's audio as well.
struct MeetingApp: Identifiable {
    let id: String            // stable key persisted in config
    let label: String         // human-readable name shown in Settings
    let bundleIDs: [String]   // bundle identifiers matched against running apps
}

extension MeetingApp {
    static let catalog: [MeetingApp] = [
        MeetingApp(id: "zoom",   label: "Zoom",
                   bundleIDs: ["us.zoom.xos",
                               "us.zoom.xos.ZoomMTRunning",
                               "us.zoom.xos.ZoomAudio"]),
        MeetingApp(id: "teams",  label: "Microsoft Teams",
                   bundleIDs: ["com.microsoft.teams",
                               "com.microsoft.teams2"]),
        MeetingApp(id: "webex",  label: "Webex",
                   bundleIDs: ["Cisco-Systems.Spark",
                               "com.cisco.webexmeetings"]),
        MeetingApp(id: "chrome", label: "Google Chrome (Meet)",
                   bundleIDs: ["com.google.Chrome"]),
        MeetingApp(id: "safari", label: "Safari (Meet)",
                   bundleIDs: ["com.apple.Safari"]),
    ]

    /// All catalog ids — the default "everything enabled" set.
    static var allIDs: [String] { catalog.map(\.id) }
}
