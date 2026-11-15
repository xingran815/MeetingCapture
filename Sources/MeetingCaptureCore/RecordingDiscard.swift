import Foundation

/// Abort: a recording the user threw away while it ran. Its audio and its sidecar go to
/// the Trash, never deleted for good, and nothing is transcribed.
///
/// Only this recording's own files move (D-44): the parts capture returned, each a plain
/// regular file in the recording's folder whose name belongs to this base and that no
/// other sidecar lists, then the sidecar, and that only while it still says `recording`
/// for this process. A similarly named file of another recording stays.
enum RecordingDiscard {

    /// Moves the aborted recording's files to the Trash, the sidecar last, and returns
    /// what moved. Stops at the first failure, so the sidecar still marks what's left as
    /// unfinished and the next launch offers it.
    ///
    /// `parts` is what capture returned. When capture failed and returned nothing, the
    /// parts are found as `RecordingFiles` finds them (`<base>.wav`, `<base>_part2.wav`, …),
    /// because this process named the base moments ago (`Config.newMeetingBase`) and the
    /// sidecar says it is still recording it. The same checks apply to each.
    ///
    /// If one of this recording's own parts can't be moved by these rules (a link, say),
    /// the sidecar stays, so the rest is still offered as unfinished and never orphaned.
    /// From the M7 reviews.
    @discardableResult
    static func trash(
        base: URL, parts: [URL], pid: Int32 = getpid(), remover: Notebook.Remover = Notebook.systemTrash
    ) throws -> [URL] {
        let dir = base.deletingLastPathComponent().standardizedFileURL.path
        let name = base.lastPathComponent
        let sidecarURL = RecordingSidecar.url(forBase: base)
        guard let sidecar = RecordingSidecar.load(at: sidecarURL), sidecar.state == .recording,
            sidecar.pid == pid
        else {
            throw DiscardError.notThisRecording(name)
        }
        let claimed = Notebook.claimedByOthers(
            in: base.deletingLastPathComponent(), except: sidecarURL.lastPathComponent)
        let candidates =
            parts.isEmpty
            ? RecordingFiles.allParts(of: base.appendingPathExtension("wav").path).map { URL(fileURLWithPath: $0) }
            : parts

        var files: [URL] = []
        var ownPartLeft: String?
        for part in candidates {
            // Paths compared as strings: URL equality also compares how a URL was spelled.
            let url = URL(fileURLWithPath: part.standardizedFileURL.path)
            let file = url.lastPathComponent
            let stem = (file as NSString).deletingPathExtension
            let own =
                url.deletingLastPathComponent().path == dir
                && ["wav", "m4a"].contains(url.pathExtension.lowercased())
                && RecordingFiles.baseName(of: stem) == name
            guard own, !files.contains(url) else { continue }
            guard !claimed.contains(file) else { continue }
            guard isRegularFile(url) else {
                if FileManager.default.fileExists(atPath: url.path) || isLink(url) { ownPartLeft = file }
                continue
            }
            files.append(url)
        }
        if ownPartLeft == nil, isRegularFile(sidecarURL) { files.append(sidecarURL) }

        var moved: [URL] = []
        for url in files {
            do { try remover(url) } catch {
                throw DiscardError.moveFailed(url.lastPathComponent, error.localizedDescription)
            }
            moved.append(url)
        }
        if let ownPartLeft { throw DiscardError.partLeft(ownPartLeft) }
        return moved
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// A regular file itself, not a link to one.
    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    enum DiscardError: Error, LocalizedError, Equatable {
        case notThisRecording(String)
        case moveFailed(String, String)
        case partLeft(String)

        var errorDescription: String? {
            switch self {
            case .notThisRecording(let name):
                return "\(name) isn't a recording this app is making, so nothing was moved."
            case .partLeft(let file):
                return
                    "\(file) isn't a plain file, so it was left, and the recording stays as unfinished. Move it yourself if you don't want it."
            case .moveFailed(let file, let reason):
                return
                    "Couldn't move \(file) to the Trash (\(reason)). What's left is offered as an unfinished recording next time."
            }
        }
    }
}
