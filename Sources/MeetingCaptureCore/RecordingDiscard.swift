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
    /// first part `<base>.wav` is the only one tried, because this process named the base
    /// moments ago (`Config.newMeetingBase`) and the sidecar says it is still recording it.
    @discardableResult
    static func trash(
        base: URL, parts: [URL], pid: Int32 = getpid(), remover: Notebook.Remover = Notebook.systemTrash
    ) throws -> [URL] {
        let dir = base.deletingLastPathComponent().standardizedFileURL
        let name = base.lastPathComponent
        let sidecarURL = RecordingSidecar.url(forBase: base)
        guard let sidecar = RecordingSidecar.load(at: sidecarURL), sidecar.state == .recording,
            sidecar.pid == pid
        else {
            throw DiscardError.notThisRecording(name)
        }
        let claimed = Notebook.claimedByOthers(in: dir, except: sidecarURL.lastPathComponent)
        let candidates = parts.isEmpty ? [base.appendingPathExtension("wav")] : parts

        var files: [URL] = []
        for part in candidates {
            let url = part.standardizedFileURL
            let file = url.lastPathComponent
            let stem = (file as NSString).deletingPathExtension
            guard url.deletingLastPathComponent() == dir,
                ["wav", "m4a"].contains(url.pathExtension.lowercased()),
                RecordingFiles.baseName(of: stem) == name,
                !claimed.contains(file),
                isRegularFile(url),
                !files.contains(url)
            else { continue }
            files.append(url)
        }
        if isRegularFile(sidecarURL) { files.append(sidecarURL) }

        var moved: [URL] = []
        for url in files {
            do { try remover(url) } catch {
                throw DiscardError.moveFailed(url.lastPathComponent, error.localizedDescription)
            }
            moved.append(url)
        }
        return moved
    }

    /// A regular file itself, not a link to one.
    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    enum DiscardError: Error, LocalizedError, Equatable {
        case notThisRecording(String)
        case moveFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .notThisRecording(let name):
                return "\(name) isn't a recording this app is making, so nothing was moved."
            case .moveFailed(let file, let reason):
                return
                    "Couldn't move \(file) to the Trash (\(reason)). What's left is offered as an unfinished recording next time."
            }
        }
    }
}
