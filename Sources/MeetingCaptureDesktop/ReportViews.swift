import MeetingCaptureCore
import SwiftUI
import WebKit

/// A recording picked in the library: its report, or what can be done without one.
struct EntryDetail: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry

    var body: some View {
        // Read so a change to the title, edits or notes draws the page again.
        let _ = model.reportRevision
        if let html = entry.reportHTML() {
            VStack(spacing: 0) {
                let stale = entry.staleEditCount()
                if stale > 0 { StaleEditsBanner(entry: entry, count: stale) }
                ReportWebView(html: html)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: entry.isUnfinished ? "exclamationmark.circle" : "doc.text")
                    .font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(headline).font(.title2.weight(.semibold))
                Text(explanation).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    if entry.isUnfinished {
                        Button("Process Now") { model.processUnfinished(entry) }.buttonStyle(.borderedProminent)
                    } else if entry.hasTranscript {
                        Button("Write the Report") { model.writeReportAgain(entry) }.buttonStyle(.borderedProminent)
                    } else if !entry.audioFiles.isEmpty {
                        Button("Transcribe") { model.transcribeAgain(entry) }.buttonStyle(.borderedProminent)
                    }
                }
                .disabled(model.isProcessing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
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
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var names: [String: String] = [:]
    @State private var speakers: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers").font(.title2.weight(.semibold))
            Text(
                "Give a speaker a name. Using another speaker's name merges the two. This changes the transcript; write the report again to use the new names."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(speakers, id: \.self) { speaker in
                    TextField(speaker, text: Binding(get: { names[speaker] ?? speaker }, set: { names[speaker] = $0 }))
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
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
