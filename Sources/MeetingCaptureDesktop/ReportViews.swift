import MeetingCaptureCore
import SwiftUI
import WebKit

/// A recording picked in the library: its report, or what can be done without one.
struct EntryDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 0) {
            content
            if model.showsNotes {
                Rectangle().fill(theme.line2).frame(width: 1)
                NotesInspector(entry: entry).frame(width: 300).background(theme.ground2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        // Read so a change to the title, edits or notes draws the page again.
        let _ = model.reportRevision
        if let html = entry.reportHTML() {
            VStack(spacing: 0) {
                let stale = entry.staleEditCount()
                if stale > 0 { StaleEditsBanner(entry: entry, count: stale) }
                ReportWebView(html: ReportTheme.apply(theme, to: html), background: theme.palette.ground)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(entry.isUnfinished ? "!" : "--").foregroundStyle(
                        entry.isUnfinished ? theme.amber : theme.faint)
                    Text(headline.uppercased()).tracking(0.8)
                }
                .font(.mono(14, .bold))
                Text(explanation).font(.mono(12.5)).foregroundStyle(theme.dim)
                    .frame(maxWidth: 480, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if entry.isUnfinished {
                        Button {
                            model.processUnfinished(entry)
                        } label: {
                            KeyedLabel("▶ Process now", inverted: true)
                        }
                        .buttonStyle(.terminal(.go))
                    } else if entry.hasTranscript {
                        Button {
                            model.writeReportAgain(entry)
                        } label: {
                            KeyedLabel("▶ Write the report", inverted: true)
                        }
                        .buttonStyle(.terminal(.go))
                    } else if !entry.audioFiles.isEmpty {
                        Button {
                            model.transcribeAgain(entry)
                        } label: {
                            KeyedLabel("▶ Transcribe", inverted: true)
                        }
                        .buttonStyle(.terminal(.go))
                    }
                }
                .disabled(model.isProcessing)
            }
            .padding(.horizontal, 30).padding(.vertical, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var headline: String {
        if entry.isUnfinished { return "This recording wasn't finished" }
        return entry.hasTranscript ? "No report yet" : "No transcript yet"
    }

    private var explanation: String {
        if entry.isUnfinished {
            return
                "The app stopped before it could transcribe it. The audio is kept; process it now to get the transcript and report."
        }
        return entry.hasTranscript
            ? "The transcript is saved. Write the report when you're ready."
            : "The audio is saved. Transcribe it to read it and get a report."
    }
}

/// The same self-contained HTML the terminal writes, in a web view that runs only the
/// page's own script (the page's CSP allows one hashed script) and sends every outside
/// link to the browser.
struct ReportWebView: NSViewRepresentable {
    let html: String
    /// The theme's ground, so the page never flashes another colour while it loads.
    var background: UInt32 = TerminalPalette.phosphor.ground

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = NSColor(Color(hex: background))
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.underPageBackgroundColor = NSColor(Color(hex: background))
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded = ""

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                Self.apply(
                    ReportNavigation.decide(
                        url: action.request.url, isLinkClick: action.navigationType == .linkActivated)))
        }

        /// `target=_blank` links come here; they never get a new view.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            _ = Self.apply(ReportNavigation.decideNewWindow(url: action.request.url))
            return nil
        }

        private static func apply(_ decision: ReportNavigation) -> WKNavigationActionPolicy {
            switch decision {
            case .allow: return .allow
            case .openInBrowser(let url):
                NSWorkspace.shared.open(url)
                return .cancel
            case .refuse: return .cancel
            }
        }
    }
}

/// Rename or merge speakers, as the terminal's "Rename or merge speakers" does.
struct SpeakersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var names: [String: String] = [:]
    @State private var speakers: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHead("speakers")
            Text(
                "Give a speaker a name. Using another speaker's name merges the two. This changes the transcript; write the report again to use the new names."
            )
            .font(.mono(12.5)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(speakers, id: \.self) { speaker in
                    TextField(speaker, text: Binding(get: { names[speaker] ?? speaker }, set: { names[speaker] = $0 }))
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            if let error { Text("! " + error).foregroundStyle(theme.rec).font(.mono(12.5)) }
            SheetButtons(cancel: { dismiss() }, confirm: ("Save", save))
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .background(theme.ground)
        .onAppear { speakers = entry.speakers() }
    }

    /// All names at once, so swapping two speakers stays a swap and a bad name
    /// changes nothing. From the M5 review.
    private func save() {
        do {
            let changes = names.filter { speakers.contains($0.key) && $0.value != $0.key }
            if try !entry.applySpeakerNames(changes) {
                error = "A name can't be empty or contain a colon."
                return
            }
            model.reload()
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Cancel and the sheet's one action, as keyed terminal buttons.
struct SheetButtons: View {
    var cancel: (() -> Void)?
    var confirm: (title: String, action: () -> Void)
    var destructive = false

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if let cancel {
                Button(action: cancel) { KeyedLabel("Cancel", keys: "esc") }
                    .buttonStyle(.terminal)
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: confirm.action) {
                KeyedLabel(confirm.title, keys: "⏎", inverted: !destructive)
            }
            .buttonStyle(.terminal(destructive ? .stop : .go))
            .keyboardShortcut(.defaultAction)
        }
    }
}
