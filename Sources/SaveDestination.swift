import AppKit
import Foundation

/// Where a pin goes when the user closes or slides it away. The screenshot is
/// moved out of the private workspace into this folder as a permanent file. The folder is picked once by
/// the user through a plain open panel and remembered; ShotPin is not sandboxed,
/// so a path is enough to reach it again.
enum SaveDestination {
    enum SaveError: LocalizedError {
        case cancelled
        case noFolder
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "没有选择存储文件夹"
            case .noFolder: return "还没有设置存储文件夹"
            case .failed(let message): return message
            }
        }
    }

    private static let folderPathKey = "saveFolderPath"
    private static let fileManager = Foundation.FileManager()

    static var folder: URL? {
        guard let path = UserDefaults.standard.string(forKey: folderPathKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    static func setFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: folderPathKey)
        UserDefaults.standard.synchronize()
    }

    /// ShotPin runs as an accessory, so it has to come forward before showing a
    /// modal panel, otherwise the panel appears behind the frontmost app.
    @discardableResult
    static func chooseFolder(startingAt current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择存储截图的文件夹"
        panel.directoryURL = current
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setFolder(url)
        return url
    }

    /// The first save has no folder yet, so it asks. A folder that has since been
    /// deleted or unmounted also asks instead of silently reappearing somewhere
    /// else — the user may have unplugged the volume it lived on.
    private static func usableFolder() throws -> URL {
        var directory: URL
        if let configured = folder {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: configured.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                directory = configured
            } else {
                guard let chosen = chooseFolder(startingAt: configured) else {
                    throw SaveError.cancelled
                }
                directory = chosen
            }
        } else {
            guard let chosen = chooseFolder(startingAt: nil) else {
                throw SaveError.cancelled
            }
            directory = chosen
        }
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
        return directory
    }

    /// Move the pinned screenshot out of the private workspace. A cross-volume
    /// destination falls back to copy-and-delete; the pin's file is temporary
    /// either way, so removing the source is safe once the copy exists.
    @discardableResult
    static func save(_ source: URL) throws -> URL {
        let directory = try usableFolder()
        let target = uniqueDestination(for: source.lastPathComponent, in: directory)
        // The save folder can also be the system screenshot directory. Mark the
        // destination before creating it, so FSEvents cannot re-pin our own save.
        EventSuppressor.shared.suppress(target, for: 30)
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            do {
                try fileManager.copyItem(at: source, to: target)
                try? fileManager.removeItem(at: source)
            } catch {
                throw SaveError.failed(error.localizedDescription)
            }
        }
        return target
    }

    static func revealFolder() {
        guard let directory = folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let original = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let source = URL(fileURLWithPath: name)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for index in 2...10_000 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

// MARK: - Suppressing our own file writes

/// Rewriting a pinned screenshot (标注 in 预览, for instance) replaces its inode,
/// which the capture watcher would otherwise report as a brand-new capture and
/// pin a second time. Paths are ignored for a while after they are handed to an
/// editor that saves in place.
final class EventSuppressor {
    static let shared = EventSuppressor()

    private var expiry: [String: Date] = [:]
    private let lock = NSLock()

    func suppress(_ url: URL, for seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        expiry[url.standardizedFileURL.path] = Date().addingTimeInterval(seconds)
    }

    func isSuppressed(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        for (path, deadline) in expiry where deadline <= now {
            expiry.removeValue(forKey: path)
        }
        return expiry[url.standardizedFileURL.path] != nil
    }
}
