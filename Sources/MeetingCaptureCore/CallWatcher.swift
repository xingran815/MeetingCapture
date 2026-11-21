import CoreAudio
import Foundation

// M9 (issue 28, D-108): notices when a meeting app starts and ends a call, so the desktop
// app can ask "Transcribe this meeting?". It only reports; it never starts capture.

/// One process holding audio input right now.
public struct MicUser: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public init(pid: Int32, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Which processes are using the microphone. The CoreAudio one is real; tests give a fake.
public protocol MicUsageSource {
    func micUsers() -> [MicUser]
}

/// CoreAudio's process objects (macOS 14.2+). Reading them asks for no permission: they
/// say which process runs input, never what it hears.
public struct CoreAudioMicUsage: MicUsageSource {
    public init() {}

    public func micUsers() -> [MicUser] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard Self.uint32(id, kAudioProcessPropertyIsRunningInput) == 1, let bundle = Self.bundleID(id) else {
                return nil
            }
            return MicUser(pid: Self.pid(id) ?? 0, bundleID: bundle)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ id: AudioObjectID) -> Int32? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
            let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }
}

/// What a browser's tabs say about a call.
public enum TabCheck: Equatable, Sendable {
    /// A tab is on a known meeting site, such as `meet.google.com`.
    case meeting(host: String)
    /// The tabs could be read and none is a meeting site.
    case notMeeting
    /// The tabs couldn't be read (Automation refused or failed): ask with the plain wording.
    case unknown
}

/// The sites a browser call counts on (D-108). Only hosts are compared; URLs are never kept.
public enum MeetingSites {
    public static let hosts = [
        "meet.google.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft", "zoom.us", "webex.com",
    ]

    /// True for one of `hosts` or a subdomain of one, on a dot boundary: `us02web.zoom.us`
    /// counts, `evilzoom.us` and `zoom.us.example.com` don't.
    public static func isMeetingHost(_ host: String) -> Bool {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return false }
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The first https URL whose host is a meeting site, as that host.
    public static func meetingHost(in urls: [String]) -> String? {
        for string in urls {
            guard let url = URL(string: string), url.scheme?.lowercased() == "https", let host = url.host,
                isMeetingHost(host)
            else { continue }
            return host.lowercased()
        }
        return nil
    }
}

/// A call the watcher noticed.
public struct DetectedCall: Equatable, Sendable {
    public let appID: String
    public let appLabel: String
    /// The meeting site for a browser call, when its tabs could be read.
    public let site: String?
    public let isBrowser: Bool

    public init(appID: String, appLabel: String, site: String?, isBrowser: Bool) {
        self.appID = appID
        self.appLabel = appLabel
        self.site = site
        self.isBrowser = isBrowser
    }

    /// The name the panel shows: "Zoom", "Chrome".
    public var appName: String {
        switch appID {
        case "chrome": return "Chrome"
        case "safari": return "Safari"
        default: return appLabel
        }
    }

    /// "Zoom is using the microphone", "Chrome has a tab on meet.google.com": any tab,
    /// which may not be the one using the mic (M9 review).
    public var sourceLine: String {
        if let site { return "\(appName) has a tab on \(site)" }
        return "\(appName) is using the microphone"
    }
}

public enum CallEvent: Equatable, Sendable {
    case started(DetectedCall)
    case ended(DetectedCall)
    /// A browser has held the mic long enough: read its tabs and pass the answer to
    /// `CallWatcher.tabsChecked`. Asked at most once every `tabRecheck` while it holds.
    case checkTabs(appID: String)
}

/// The pure part: given who holds the mic now, which calls started and ended. Times come
/// from the caller, so tests run without waiting.
public final class CallWatcher {
    /// The catalog ids to watch. An app outside it is never reported.
    public var appIDs: Set<String>
    /// How long an app must hold the mic before it counts as a call.
    public let startHold: TimeInterval
    /// Longer for a browser: a voice message or a dictation shouldn't count.
    public let browserHold: TimeInterval
    /// How long the mic must stay released before the call counts as ended, so a mute
    /// or a device switch isn't a new call.
    public let endGrace: TimeInterval
    /// How often a browser that holds the mic but showed no meeting site is checked again.
    public let tabRecheck: TimeInterval

    private struct AppState {
        var holdingSince: Date?
        var lastHeld: Date?
        var call: DetectedCall?
        var tabsAskedAt: Date?
        var tabs: TabCheck?
    }

    private var state: [String: AppState] = [:]
    private let catalog: [MeetingApp]

    public init(
        appIDs: Set<String>? = nil, startHold: TimeInterval = 3, browserHold: TimeInterval = 10,
        endGrace: TimeInterval = 10, tabRecheck: TimeInterval = 10
    ) {
        self.appIDs = appIDs ?? Set(MeetingApp.allIDs)
        self.startHold = startHold
        self.browserHold = browserHold
        self.endGrace = endGrace
        self.tabRecheck = tabRecheck
        catalog = MeetingApp.catalog
    }

    /// The calls under way now.
    public var activeCalls: [DetectedCall] { catalog.compactMap { state[$0.id]?.call } }

    /// The answer to a `.checkTabs` event; used on the next `update`.
    /// An answer for a hold that has since ended is dropped (M9 review), so a later hold
    /// gets a fresh check.
    public func tabsChecked(appID: String, _ result: TabCheck) {
        guard var s = state[appID], s.tabsAskedAt != nil, s.holdingSince != nil else { return }
        s.tabs = result
        state[appID] = s
    }

    /// One look at the mic. `running` holds the bundle IDs of running apps; it tells a
    /// Safari call from another WebKit app's (unsure, spec 08).
    public func update(now: Date, users: [MicUser], running: Set<String>) -> [CallEvent] {
        var events: [CallEvent] = []
        for app in catalog {
            var s = state[app.id] ?? AppState()
            let watched = appIDs.contains(app.id)
            let held = watched && users.contains { Self.matches(app, bundleID: $0.bundleID, running: running) }
            if held {
                s.lastHeld = now
                if s.holdingSince == nil { s.holdingSince = now }
                if s.call == nil, let since = s.holdingSince,
                    now.timeIntervalSince(since) >= (app.isBrowser ? browserHold : startHold)
                {
                    if app.isBrowser {
                        switch s.tabs {
                        case .meeting(let host):
                            s.call = DetectedCall(appID: app.id, appLabel: app.label, site: host, isBrowser: true)
                        case .unknown:
                            s.call = DetectedCall(appID: app.id, appLabel: app.label, site: nil, isBrowser: true)
                        case .notMeeting, nil:
                            if s.tabsAskedAt == nil || now.timeIntervalSince(s.tabsAskedAt!) >= tabRecheck {
                                s.tabsAskedAt = now
                                s.tabs = nil
                                events.append(.checkTabs(appID: app.id))
                            }
                        }
                    } else {
                        s.call = DetectedCall(appID: app.id, appLabel: app.label, site: nil, isBrowser: false)
                    }
                    if let call = s.call { events.append(.started(call)) }
                }
            } else if let last = s.lastHeld, now.timeIntervalSince(last) >= endGrace || !watched {
                if let call = s.call { events.append(.ended(call)) }
                s = AppState()
            } else if s.call == nil {
                // A short hold that never became a call starts over.
                s.holdingSince = nil
            }
            state[app.id] = s
        }
        return events
    }

    /// The app's own bundle ID or a helper of it (`com.google.Chrome.helper`). Safari's
    /// audio runs in WebKit's shared GPU process, which counts only while Safari runs.
    static func matches(_ app: MeetingApp, bundleID: String, running: Set<String>) -> Bool {
        if app.bundleIDs.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) { return true }
        if app.id == "safari", bundleID.hasPrefix("com.apple.WebKit."), running.contains("com.apple.Safari") {
            return true
        }
        return false
    }
}
