import AppKit
import ApplicationServices
import Vision
import CoreServices
import Darwin
import Foundation
import ImageIO
import QuickLookUI
import QuartzCore
import UniformTypeIdentifiers

// ShotPin: keeps the newest screenshot pinned in the bottom-right corner of the
// screen until you actually do something with it. Replaces the native macOS
// thumbnail, which disappears after a few seconds.

private enum Style {
    static let maxDimension: CGFloat = 220
    static let padding: CGFloat = 18
    static let corner: CGFloat = 8
    static let screenMargin: CGFloat = 18
    static let stackSpacing: CGFloat = 10
}

private let watchedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf"]
private let recordingExtensions: Set<String> = ["mov", "mp4"]
private let shotFileManager = Foundation.FileManager()

private func makeIconWiggle(for layer: CALayer, duration: CFTimeInterval = 0.8) -> CAAnimationGroup {
    let angles = (0...60).map { -0.025 * sin(2 * Double.pi * Double($0) / 60) }
    let centerX = layer.bounds.width * (0.5 - layer.anchorPoint.x)
    let centerY = layer.bounds.height * (0.5 - layer.anchorPoint.y)
    let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    rotation.values = angles
    rotation.calculationMode = .linear
    let offset = CAKeyframeAnimation(keyPath: "position")
    offset.values = angles.map { angle in
        NSValue(point: CGPoint(x: centerX * (1 - cos(angle)) + centerY * sin(angle),
                               y: centerY * (1 - cos(angle)) - centerX * sin(angle)))
    }
    offset.isAdditive = true
    offset.calculationMode = .linear
    let animation = CAAnimationGroup()
    animation.animations = [rotation, offset]
    animation.duration = duration
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    return animation
}

// Paths of pins that should survive a restart. The workspace cleanup keeps
// these files until the user saves, deletes, or dismisses their windows.
private enum PendingPins {
    private static let key = "pendingPinPaths.v1"
    static var paths: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var current = paths
        if !current.contains(path) { current.append(path) }
        UserDefaults.standard.set(current, forKey: key)
        if !UserDefaults.standard.synchronize() { NSLog("ShotPin: could not persist pin list") }
    }
    static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        UserDefaults.standard.set(paths.filter { $0 != path }, forKey: key)
        if !UserDefaults.standard.synchronize() { NSLog("ShotPin: could not persist pin removal") }
    }
    static func contains(_ url: URL) -> Bool { paths.contains(url.standardizedFileURL.path) }
}

private enum PinPlacement: String, CaseIterable {
    case right, left, top
    var title: String {
        switch self { case .right: return "右边"; case .left: return "左边"; case .top: return "上边" }
    }
    static var current: PinPlacement {
        get { PinPlacement(rawValue: UserDefaults.standard.string(forKey: "pinPlacement") ?? "") ?? .right }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pinPlacement") }
    }
}

private enum StackCorner {
    static func remember(left: Bool, bottom: Bool, screen: NSScreen) {
        let defaults = UserDefaults.standard
        defaults.set(left, forKey: "stackCorner.left")
        defaults.set(bottom, forKey: "stackCorner.bottom")
        defaults.set(Int(screen.displayID), forKey: "stackCorner.display")
    }
    static var left: Bool { UserDefaults.standard.bool(forKey: "stackCorner.left") }
    static var bottom: Bool {
        UserDefaults.standard.object(forKey: "stackCorner.bottom") as? Bool ?? true
    }
    static var displayID: CGDirectDisplayID? {
        guard let number = UserDefaults.standard.object(forKey: "stackCorner.display") as? NSNumber else { return nil }
        return number.uint32Value
    }
}

// MARK: - Private capture workspace

/// Redirects macOS' normal screenshot machinery into a private, per-run folder.
/// The original destination is restored when ShotPin exits, and stale state from
/// an interrupted prior run is repaired the next time ShotPin launches.
final class CaptureWorkspace {
    static let shared = CaptureWorkspace()

    enum WorkspaceError: LocalizedError {
        case alreadyRunning
        case lockFailed(String, Int32)
        case unsafeRoot(String)
        case preferencesUpdateFailed

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "another ShotPin instance is already running"
            case .lockFailed(let path, let code):
                return "could not lock \(path) (errno \(code))"
            case .unsafeRoot(let path):
                return "refusing to use unsafe workspace root \(path)"
            case .preferencesUpdateFailed:
                return "could not update the macOS screenshot location"
            }
        }
    }

    private enum Key {
        static let active = "captureWorkspace.active"
        static let path = "captureWorkspace.path"
        static let token = "captureWorkspace.token"
        static let endedAt = "captureWorkspace.endedAt"
        static let previousLocation = "captureWorkspace.previousLocation"
        static let previousLocationExisted = "captureWorkspace.previousLocationExisted"
        static let staleWorkspaces = "captureWorkspace.staleWorkspaces"
    }

    private struct StaleWorkspace {
        let path: String
        let token: String?
        let previousLocation: String?
        let previousLocationExisted: Bool
        let endedAt: Date

        init(path: String,
             token: String?,
             previousLocation: String?,
             previousLocationExisted: Bool,
             endedAt: Date) {
            self.path = path
            self.token = token
            self.previousLocation = previousLocation
            self.previousLocationExisted = previousLocationExisted
            self.endedAt = endedAt
        }

        init?(propertyList: [String: Any]) {
            guard let path = propertyList["path"] as? String,
                  let existed = propertyList["previousLocationExisted"] as? Bool,
                  let endedAt = propertyList["endedAt"] as? Date else { return nil }
            self.init(path: path,
                      token: propertyList["token"] as? String,
                      previousLocation: propertyList["previousLocation"] as? String,
                      previousLocationExisted: existed,
                      endedAt: endedAt)
        }

        var propertyList: [String: Any] {
            var value: [String: Any] = [
                "path": path,
                "previousLocationExisted": previousLocationExisted,
                "endedAt": endedAt
            ]
            if let token { value["token"] = token }
            if let previousLocation { value["previousLocation"] = previousLocation }
            return value
        }
    }

    private let appDefaults = UserDefaults.standard
    private let captureDomain = "com.apple.screencapture" as CFString
    private let stateRoot = (shotFileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
        ?? shotFileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true))
        .appendingPathComponent("ShotPin", isDirectory: true)
    private var workspaceRoot: URL {
        stateRoot.appendingPathComponent("Capture Workspaces", isDirectory: true)
    }
    private var ownershipRoot: URL {
        stateRoot.appendingPathComponent("Workspace Ownership", isDirectory: true)
    }
    private var lockDescriptor: Int32 = -1
    private var ownsSession = false
    private var sessionToken: String?
    private var staleCleanupRunning = false
    private let cleanupQueue = DispatchQueue(label: "app.shotpin.workspace-cleanup", qos: .utility)
    private let terminationCleanupQueue = DispatchQueue(
        label: "app.shotpin.termination-cleanup",
        qos: .userInitiated
    )
    private(set) var directory: URL?

    private init() {}

    func begin() throws {
        try shotFileManager.createDirectory(at: stateRoot,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        try validateDirectory(stateRoot)
        try acquireProcessLock()

        do {
            try shotFileManager.createDirectory(at: workspaceRoot,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            try validateDirectory(workspaceRoot)
            try shotFileManager.createDirectory(at: ownershipRoot,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            try validateDirectory(ownershipRoot)
            try recoverInterruptedSession()

            let previousLocation = currentCaptureLocation()
            let workspace = workspaceRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let token = UUID().uuidString
            try shotFileManager.createDirectory(at: workspace,
                                                withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
            try token.write(to: ownershipMarker(for: workspace),
                            atomically: true,
                            encoding: .utf8)

            // Persist recovery information before changing the global capture setting.
            appDefaults.set(true, forKey: Key.active)
            appDefaults.set(workspace.path, forKey: Key.path)
            appDefaults.set(token, forKey: Key.token)
            appDefaults.set(previousLocation != nil, forKey: Key.previousLocationExisted)
            if let previousLocation {
                appDefaults.set(previousLocation, forKey: Key.previousLocation)
            } else {
                appDefaults.removeObject(forKey: Key.previousLocation)
            }
            guard appDefaults.synchronize() else {
                throw WorkspaceError.preferencesUpdateFailed
            }

            directory = workspace
            sessionToken = token
            ownsSession = true
        } catch {
            releaseProcessLock()
            throw error
        }
    }

    /// Activate the redirect only after the watcher is live. Captures made during
    /// startup then remain in the user's normal destination instead of entering an
    /// unwatched workspace.
    func activate() throws {
        guard ownsSession, let directory else { return }
        guard setCaptureLocation(directory.path) else {
            throw WorkspaceError.preferencesUpdateFailed
        }
    }

    /// Honor a destination change made while ShotPin is running, then resume the
    /// private redirect so subsequent captures continue to be watched. The new
    /// destination becomes the one restored at shutdown.
    func maintainRedirect() -> Bool {
        guard ownsSession, let directory else { return false }
        guard CFPreferencesAppSynchronize(captureDomain) else { return false }
        let current = currentCaptureLocation()
        guard !locationsMatch(current, directory.path) else { return true }
        savePreviousLocation(current)
        guard appDefaults.synchronize() else { return false }
        return setCaptureLocation(directory.path)
    }

    func end(completion: @escaping () -> Void) {
        guard ownsSession, let workspace = directory, let token = sessionToken else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        appDefaults.set(Date(), forKey: Key.endedAt)
        let restored = restorePreviousLocation(expectedWorkspace: workspace)
        if !restored {
            NSLog("ShotPin: could not restore the screenshot destination; recovery remains active")
        }
        let destination = previousCaptureDirectory()

        // Delete closed screenshots without waiting behind a stale recording copy.
        // Recordings and recently changing files remain under the durable active
        // record for the next launch to retire after its normal grace period.
        terminationCleanupQueue.async { [self] in
            let complete = discardWorkspace(at: workspace,
                                            token: token,
                                            destination: destination,
                                            allowCrossVolumeRecordingMoves: false,
                                            removeWorkspace: false,
                                            processRecordings: false)
            DispatchQueue.main.async { [self] in
                finishSession(workspace: workspace, cleanupComplete: complete)
                completion()
            }
        }
    }

    private func finishSession(workspace: URL, cleanupComplete: Bool) {
        if cleanupComplete {
            clearRecoveryState()
        } else {
            // Keep a trustworthy recovery pointer so the next launch can retry.
            appDefaults.set(true, forKey: Key.active)
            appDefaults.set(workspace.path, forKey: Key.path)
            if let sessionToken { appDefaults.set(sessionToken, forKey: Key.token) }
            NSLog("ShotPin: workspace cleanup is incomplete; it will be retried at %@",
                  workspace.path)
        }
        directory = nil
        sessionToken = nil
        ownsSession = false
        if !appDefaults.synchronize() {
            NSLog("ShotPin: could not flush workspace recovery state before exit")
        }
        // Keep the process lock until exit. A stale-cleanup callback from this
        // process must not race a new instance's recovery-state update.
    }

    private func recoverInterruptedSession() throws {
        guard appDefaults.bool(forKey: Key.active) else { return }
        if let path = appDefaults.string(forKey: Key.path) {
            guard restorePreviousLocation(expectedWorkspace: URL(fileURLWithPath: path)) else {
                throw WorkspaceError.preferencesUpdateFailed
            }
            enqueueStaleWorkspace(StaleWorkspace(
                path: path,
                token: appDefaults.string(forKey: Key.token),
                previousLocation: appDefaults.string(forKey: Key.previousLocation),
                previousLocationExisted: appDefaults.bool(forKey: Key.previousLocationExisted),
                endedAt: (appDefaults.object(forKey: Key.endedAt) as? Date) ?? Date()
            ))
        }
        clearRecoveryState()
    }

    func cleanupStaleWorkspaces() {
        guard !staleCleanupRunning else { return }
        let records = staleWorkspaces()
        guard !records.isEmpty else { return }
        staleCleanupRunning = true

        cleanupQueue.async { [self] in
            let remaining = records.filter { record in
                guard Date().timeIntervalSince(record.endedAt) >= 6 else { return true }
                let destination = captureDirectory(location: record.previousLocation,
                                                   existed: record.previousLocationExisted)
                return !discardWorkspace(at: URL(fileURLWithPath: record.path),
                                         token: record.token,
                                         destination: destination,
                                         allowCrossVolumeRecordingMoves: true,
                                         removeWorkspace: true)
            }
            DispatchQueue.main.async { [self] in
                appDefaults.set(remaining.map(\.propertyList), forKey: Key.staleWorkspaces)
                if !appDefaults.synchronize() {
                    NSLog("ShotPin: could not flush the stale-workspace queue")
                }
                staleCleanupRunning = false
            }
        }
    }

    private func enqueueStaleWorkspace(_ record: StaleWorkspace) {
        var records = staleWorkspaces().filter { $0.path != record.path }
        records.append(record)
        appDefaults.set(records.map(\.propertyList), forKey: Key.staleWorkspaces)
    }

    private func staleWorkspaces() -> [StaleWorkspace] {
        (appDefaults.array(forKey: Key.staleWorkspaces) as? [[String: Any]] ?? [])
            .compactMap(StaleWorkspace.init(propertyList:))
    }

    private func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkspaceError.unsafeRoot(directory.path)
        }
    }

    private func acquireProcessLock() throws {
        let lockPath = stateRoot.appendingPathComponent("runtime.lock").path
        let descriptor = open(lockPath,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceError.lockFailed(lockPath, errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw WorkspaceError.alreadyRunning }
            throw WorkspaceError.lockFailed(lockPath, code)
        }
        lockDescriptor = descriptor
    }

    private func releaseProcessLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    @discardableResult
    private func restorePreviousLocation(expectedWorkspace: URL) -> Bool {
        guard CFPreferencesAppSynchronize(captureDomain) else { return false }
        let current = currentCaptureLocation()
        if !locationsMatch(current, expectedWorkspace.path) {
            // A user or another tool changed the destination after our redirect.
            // Preserve that choice rather than overwriting it with stale state.
            savePreviousLocation(current)
            return appDefaults.synchronize()
        }
        if appDefaults.bool(forKey: Key.previousLocationExisted),
           let location = appDefaults.string(forKey: Key.previousLocation) {
            return setCaptureLocation(location)
        } else {
            CFPreferencesSetAppValue("location" as CFString, nil, captureDomain)
            guard CFPreferencesAppSynchronize(captureDomain) else { return false }
            return currentCaptureLocation() == nil
        }
    }

    private func currentCaptureLocation() -> String? {
        CFPreferencesCopyAppValue("location" as CFString, captureDomain) as? String
    }

    private func savePreviousLocation(_ location: String?) {
        appDefaults.set(location != nil, forKey: Key.previousLocationExisted)
        if let location {
            appDefaults.set(location, forKey: Key.previousLocation)
        } else {
            appDefaults.removeObject(forKey: Key.previousLocation)
        }
    }

    private func locationsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let left = URL(fileURLWithPath: (lhs as NSString).expandingTildeInPath).standardizedFileURL
        let right = URL(fileURLWithPath: (rhs as NSString).expandingTildeInPath).standardizedFileURL
        return left == right
    }

    @discardableResult
    private func setCaptureLocation(_ path: String) -> Bool {
        CFPreferencesSetAppValue("location" as CFString, path as CFString, captureDomain)
        guard CFPreferencesAppSynchronize(captureDomain) else { return false }
        return locationsMatch(currentCaptureLocation(), path)
    }

    /// The screenshot preference also controls screen recordings made through
    /// Command-Shift-5. Preserve those in the user's original destination while
    /// deleting screenshots and other private workspace contents.
    @discardableResult
    private func ownershipMarker(for workspace: URL) -> URL {
        ownershipRoot.appendingPathComponent(workspace.lastPathComponent + ".token")
    }

    private func discardWorkspace(at workspace: URL,
                                  token: String?,
                                  destination: URL,
                                  allowCrossVolumeRecordingMoves: Bool,
                                  removeWorkspace: Bool,
                                  processRecordings: Bool = true) -> Bool {
        let candidate = workspace.standardizedFileURL
        guard UUID(uuidString: candidate.lastPathComponent) != nil else {
            NSLog("ShotPin: refusing to clean unowned workspace %@", workspace.path)
            return false
        }
        if token != nil {
            let expectedRoot = workspaceRoot.standardizedFileURL
            guard candidate.deletingLastPathComponent() == expectedRoot,
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                    == expectedRoot.resolvingSymlinksInPath() else {
                NSLog("ShotPin: refusing to clean workspace outside the private root %@",
                      workspace.path)
                return false
            }
        } else {
            // Compatibility for recovery state written before ownership markers existed.
            let legacyRoot = shotFileManager.temporaryDirectory
                .appendingPathComponent("ShotPin", isDirectory: true)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent() == legacyRoot,
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                    == legacyRoot.resolvingSymlinksInPath() else {
                NSLog("ShotPin: refusing to clean unowned legacy workspace %@", workspace.path)
                return false
            }
        }
        let marker = ownershipMarker(for: candidate)
        guard shotFileManager.fileExists(atPath: candidate.path) else {
            try? shotFileManager.removeItem(at: marker)
            try? shotFileManager.removeItem(at: moveJournalURL(for: candidate))
            return true
        }
        guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            NSLog("ShotPin: refusing to clean unsafe workspace %@", workspace.path)
            return false
        }
        if let token {
            guard let markerToken = try? String(contentsOf: marker, encoding: .utf8),
                  markerToken == token else {
                NSLog("ShotPin: refusing to clean workspace with invalid ownership marker %@",
                      workspace.path)
                return false
            }
        }
        guard var moveJournal = loadMoveJournal(for: candidate),
              let contents = try? shotFileManager.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return false }

        var complete = true
        for url in contents {
            let isRecording = recordingExtensions.contains(url.pathExtension.lowercased())
            if isRecording {
                guard processRecordings else {
                    complete = false
                    continue
                }
                do {
                    let fileValues = try url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ])
                    guard fileValues.isRegularFile == true,
                          fileValues.isSymbolicLink != true else {
                        complete = false
                        NSLog("ShotPin: refusing to preserve non-regular recording at %@", url.path)
                        continue
                    }
                    try shotFileManager.createDirectory(at: destination,
                                                        withIntermediateDirectories: true)
                    let resolvedDestination = destination.resolvingSymlinksInPath()
                        .standardizedFileURL
                    let destinationValues = try resolvedDestination.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey
                    ])
                    guard destinationValues.isDirectory == true,
                          destinationValues.isSymbolicLink != true,
                          !isContained(resolvedDestination, in: candidate) else {
                        complete = false
                        NSLog("ShotPin: refusing an unsafe recording directory at %@",
                              destination.path)
                        continue
                    }
                    let crossesVolumes = !sameVolume(url, resolvedDestination)
                    if isFileOpen(url) != false {
                        complete = false
                        NSLog("ShotPin: deferring open recording at %@", url.path)
                        continue
                    }
                    if crossesVolumes && !allowCrossVolumeRecordingMoves {
                        complete = false
                        NSLog("ShotPin: deferring cross-volume recording move at %@", url.path)
                        continue
                    }
                    if crossesVolumes || moveJournal[url.lastPathComponent] != nil {
                        guard let target = journaledDestination(for: url,
                                                                workspace: candidate,
                                                                destination: resolvedDestination,
                                                                journal: &moveJournal) else {
                            complete = false
                            continue
                        }
                        let staging = resolvedDestination.appendingPathComponent(
                            ".shotpin-\(candidate.lastPathComponent).partial"
                        )
                        try preserveCrossVolumeRecording(at: url,
                                                       to: target,
                                                       through: staging)
                        moveJournal.removeValue(forKey: url.lastPathComponent)
                        if !persistMoveJournal(moveJournal, for: candidate) {
                            complete = false
                        }
                    } else {
                        let target = uniqueDestination(for: url.lastPathComponent,
                                                       in: resolvedDestination)
                        try shotFileManager.moveItem(at: url, to: target)
                    }
                } catch {
                    complete = false
                    NSLog("ShotPin: could not preserve recording at %@: %@",
                          url.path, error.localizedDescription)
                }
            } else {
                if PendingPins.contains(url) {
                    complete = false
                    continue
                }
                if let attributes = try? shotFileManager.attributesOfItem(atPath: url.path),
                   let modified = attributes[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) < 2 {
                    complete = false
                    NSLog("ShotPin: deferring cleanup of recently modified file at %@", url.path)
                    continue
                }
                if unlink(url.path) != 0 {
                    complete = false
                    let code = errno
                    NSLog("ShotPin: could not unlink workspace item at %@ (errno %d)",
                          url.path, code)
                }
            }
        }

        if complete && removeWorkspace {
            if rmdir(candidate.path) == 0 {
                try? shotFileManager.removeItem(at: marker)
                try? shotFileManager.removeItem(at: moveJournalURL(for: candidate))
            } else {
                complete = false
                NSLog("ShotPin: workspace changed during cleanup at %@", candidate.path)
            }
        } else if !removeWorkspace {
            // Keep the path and ownership record through process exit so a native
            // capture that already selected this directory can still publish safely.
            complete = false
        }
        return complete
    }

    private func moveJournalURL(for workspace: URL) -> URL {
        ownershipRoot.appendingPathComponent(workspace.lastPathComponent + ".moves.plist")
    }

    /// A destination is committed before a cross-volume copy starts. If ShotPin
    /// stops after publishing the copy but before deleting the source, the next
    /// pass retries source removal against the same file instead of making a new
    /// uniquely named duplicate.
    private func journaledDestination(for source: URL,
                                      workspace: URL,
                                      destination: URL,
                                      journal: inout [String: String]) -> URL? {
        let key = source.lastPathComponent
        let expectedParent = destination.standardizedFileURL
        if let savedPath = journal[key] {
            let saved = URL(fileURLWithPath: savedPath).resolvingSymlinksInPath()
                .standardizedFileURL
            guard validJournalDestination(saved,
                                          for: source,
                                          workspace: workspace,
                                          destination: expectedParent,
                                          journal: journal) else {
                NSLog("ShotPin: refusing an invalid recording destination at %@", saved.path)
                return nil
            }
            return saved
        }

        let reserved = Set(journal.values.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let target = uniqueDestination(for: key, in: expectedParent, reserved: reserved)
        guard validJournalDestination(target,
                                      for: source,
                                      workspace: workspace,
                                      destination: expectedParent,
                                      journal: journal) else {
            NSLog("ShotPin: refusing an unsafe recording destination at %@", target.path)
            return nil
        }
        journal[key] = target.path
        guard persistMoveJournal(journal, for: workspace) else {
            journal.removeValue(forKey: key)
            return nil
        }
        return target
    }

    private func validJournalDestination(_ target: URL,
                                         for source: URL,
                                         workspace: URL,
                                         destination: URL,
                                         journal: [String: String]) -> Bool {
        let normalized = target.standardizedFileURL
        let staging = destination.appendingPathComponent(
            ".shotpin-\(workspace.lastPathComponent).partial"
        ).standardizedFileURL
        guard normalized.deletingLastPathComponent() == destination,
              normalized != source.standardizedFileURL,
              normalized != staging,
              !normalized.lastPathComponent.hasPrefix("."),
              !isContained(normalized, in: workspace),
              !isContained(staging, in: workspace) else { return false }

        return !journal.contains { key, savedPath in
            key != source.lastPathComponent
                && URL(fileURLWithPath: savedPath).resolvingSymlinksInPath()
                    .standardizedFileURL == normalized
        }
    }

    private func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let candidateParts = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let directoryParts = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard candidateParts.count >= directoryParts.count else { return false }
        return zip(directoryParts, candidateParts).allSatisfy(==)
    }

    private func loadMoveJournal(for workspace: URL) -> [String: String]? {
        let url = moveJournalURL(for: workspace)
        guard shotFileManager.fileExists(atPath: url.path) else { return [:] }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                           .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                NSLog("ShotPin: refusing an unsafe recording move journal at %@", url.path)
                return nil
            }
            let data = try Data(contentsOf: url)
            guard let value = try PropertyListSerialization.propertyList(from: data,
                                                                          format: nil)
                    as? [String: String] else {
                NSLog("ShotPin: could not read recording move journal at %@", url.path)
                return nil
            }
            return value
        } catch {
            NSLog("ShotPin: could not read recording move journal at %@: %@",
                  url.path, error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    private func persistMoveJournal(_ journal: [String: String], for workspace: URL) -> Bool {
        let url = moveJournalURL(for: workspace)
        do {
            if shotFileManager.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                               .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    NSLog("ShotPin: refusing to replace an unsafe recording move journal at %@",
                          url.path)
                    return false
                }
            }
            if journal.isEmpty {
                try? shotFileManager.removeItem(at: url)
            } else {
                let data = try PropertyListSerialization.data(fromPropertyList: journal,
                                                               format: .binary,
                                                               options: 0)
                try data.write(to: url, options: .atomic)
            }
            return true
        } catch {
            NSLog("ShotPin: could not update recording move journal at %@: %@",
                  url.path, error.localizedDescription)
            return false
        }
    }

    private func preserveCrossVolumeRecording(at source: URL,
                                              to target: URL,
                                              through staging: URL) throws {
        let workspace = source.deletingLastPathComponent()
        guard target.standardizedFileURL != staging.standardizedFileURL,
              target.standardizedFileURL != source.standardizedFileURL,
              !isContained(target, in: workspace),
              !isContained(staging, in: workspace) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if shotFileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey,
                                                              .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  sameFileIdentity(source, target) == false,
                  shotFileManager.contentsEqual(atPath: source.path,
                                                andPath: target.path),
                  isFileOpen(source) == false else {
                throw CocoaError(.fileWriteFileExists)
            }
            try shotFileManager.removeItem(at: source)
            try? shotFileManager.removeItem(at: staging)
            return
        }

        try? shotFileManager.removeItem(at: staging)
        try shotFileManager.copyItem(at: source, to: staging)
        guard isFileOpen(source) == false,
              sameFileIdentity(source, staging) == false,
              !isContained(staging, in: workspace),
              shotFileManager.contentsEqual(atPath: source.path,
                                            andPath: staging.path) else {
            try? shotFileManager.removeItem(at: staging)
            throw CocoaError(.fileReadCorruptFile)
        }
        try shotFileManager.moveItem(at: staging, to: target)
        guard sameFileIdentity(source, target) == false,
              !isContained(target, in: workspace),
              shotFileManager.contentsEqual(atPath: source.path,
                                            andPath: target.path),
              isFileOpen(source) == false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try shotFileManager.removeItem(at: source)
    }

    private func sameFileIdentity(_ first: URL, _ second: URL) -> Bool? {
        guard let firstAttributes = try? shotFileManager.attributesOfItem(atPath: first.path),
              let secondAttributes = try? shotFileManager.attributesOfItem(atPath: second.path),
              let firstDevice = firstAttributes[.systemNumber] as? NSNumber,
              let secondDevice = secondAttributes[.systemNumber] as? NSNumber,
              let firstInode = firstAttributes[.systemFileNumber] as? NSNumber,
              let secondInode = secondAttributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return firstDevice == secondDevice && firstInode == secondInode
    }

    private func sameVolume(_ file: URL, _ directory: URL) -> Bool {
        guard let fileDevice = (try? shotFileManager.attributesOfItem(atPath: file.path))?[.systemNumber]
                as? NSNumber,
              let directoryDevice = (try? shotFileManager.attributesOfItem(atPath: directory.path))?[.systemNumber]
                as? NSNumber else { return false }
        return fileDevice == directoryDevice
    }

    /// Cross-volume moves are copy-and-delete operations, so only start one after
    /// no process has the recording open. An unavailable or inconclusive lsof check
    /// is treated conservatively and retried by the stale-workspace queue.
    private func isFileOpen(_ url: URL) -> Bool? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", url.path]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        if process.terminationStatus == 0 { return true }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 1 && errorData.isEmpty { return false }
        return nil
    }

    private func previousCaptureDirectory() -> URL {
        captureDirectory(location: appDefaults.string(forKey: Key.previousLocation),
                         existed: appDefaults.bool(forKey: Key.previousLocationExisted))
    }

    private func captureDirectory(location: String?, existed: Bool) -> URL {
        if existed, let path = location, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return shotFileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    private func uniqueDestination(for name: String,
                                   in directory: URL,
                                   reserved: Set<String> = []) -> URL {
        let original = directory.appendingPathComponent(name)
        guard shotFileManager.fileExists(atPath: original.path)
                || reserved.contains(original.standardizedFileURL.path) else { return original }
        let source = URL(fileURLWithPath: name)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for index in 2...10_000 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !shotFileManager.fileExists(atPath: candidate.path),
               !reserved.contains(candidate.standardizedFileURL.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func clearRecoveryState() {
        appDefaults.removeObject(forKey: Key.active)
        appDefaults.removeObject(forKey: Key.path)
        appDefaults.removeObject(forKey: Key.token)
        appDefaults.removeObject(forKey: Key.endedAt)
        appDefaults.removeObject(forKey: Key.previousLocation)
        appDefaults.removeObject(forKey: Key.previousLocationExisted)
    }
}

// MARK: - Where screenshots land

func screenshotDirectory() -> URL {
    if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
       !location.isEmpty {
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
    }
    return shotFileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
}

/// Move completed screenshots into the pin workspace while leaving the system's
/// shared screenshot/recording destination unchanged.
func moveCaptureToWorkspace(_ source: URL, workspace: URL) throws -> URL {
    let target = SaveDestination.uniqueDestination(for: source.lastPathComponent, in: workspace)
    do {
        try shotFileManager.moveItem(at: source, to: target)
    } catch {
        // Cross-volume moves can require a copy. Never remove the source until
        // the complete copy has been written successfully.
        try shotFileManager.copyItem(at: source, to: target)
        do {
            try shotFileManager.removeItem(at: source)
        } catch {
            try? shotFileManager.removeItem(at: target)
            throw error
        }
    }
    return target
}

/// Spotlight knows whether a file came from the screenshot machinery. Returns nil
/// while the metadata has not been written yet, so callers can retry.
func isScreenCapture(_ url: URL) -> Bool? {
    guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
    guard let raw = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return nil }
    return (raw as? NSNumber)?.boolValue ?? false
}

/// macOS stores the capture rectangle as a binary plist in an extended
/// attribute, in global coordinates measured down from the primary screen.
private func captureScreenRect(_ url: URL) -> NSRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let length = getxattr(url.path, name, nil, 0, 0, 0)
    guard length > 0, length <= 4096 else { return nil }
    var bytes = [UInt8](repeating: 0, count: length)
    let read = bytes.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
    guard read == length,
          let values = (try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)) as? [NSNumber],
          values.count == 4, let main = NSScreen.screens.first else { return nil }
    let x = values[0].doubleValue, y = values[1].doubleValue
    let width = values[2].doubleValue, height = values[3].doubleValue
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 1, height > 1 else { return nil }
    let rect = NSRect(x: x, y: main.frame.maxY - y - height, width: width, height: height)
    guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
    return rect
}

/// Spotlight is authoritative when it has an answer. This fallback is deliberately
/// narrow: it only recognizes macOS' generated screenshot names, never arbitrary
/// fresh images dropped into the watched directory.
func hasGeneratedScreenshotName(_ url: URL, defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture")) -> Bool {
    let configuredName = defaults?.string(forKey: "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = [configuredName, "Screen Shot", "Screenshot"].compactMap { value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value
    }
    let stem = url.deletingPathExtension().lastPathComponent
    return prefixes.contains { prefix in
        guard stem.hasPrefix(prefix + " ") else { return false }
        return stem.dropFirst(prefix.count + 1).contains(where: \Character.isNumber)
    }
}

// MARK: - The pinned card

private final class ShotQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ShotQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.url = url
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.refreshCurrentPreviewItem()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index == 0, let url else { return nil }
        return url as NSURL
    }
}

private final class GestureHint {
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?

    func show(_ text: String, beside owner: NSWindow, delay: TimeInterval, onShow: @escaping () -> Void = {}) {
        hide()
        let work = DispatchWorkItem { [weak self, weak owner] in
            guard let self, let owner, owner.isVisible, let screen = owner.screen else { return }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.sizeToFit()
            let size = NSSize(width: label.frame.width + 16, height: label.frame.height + 8)
            let area = screen.visibleFrame
            let x = owner.frame.midX > area.midX ? owner.frame.minX - size.width : owner.frame.maxX
            let frame = NSRect(x: max(area.minX, min(x, area.maxX - size.width)),
                               y: max(area.minY, min(owner.frame.midY - size.height / 2, area.maxY - size.height)),
                               width: size.width, height: size.height)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            let body = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            body.material = .popover
            body.state = .active
            body.wantsLayer = true
            body.layer?.cornerRadius = 6
            body.layer?.masksToBounds = true
            label.setFrameOrigin(NSPoint(x: 8, y: 4))
            body.addSubview(label)
            panel.contentView = body
            owner.addChildWindow(panel, ordered: .above)
            self.panel = panel
            onShow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self, weak panel] in
                if let panel, self?.panel === panel { self?.hide() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func hide() {
        pending?.cancel()
        pending = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }
}

final class ShotView: NSView, NSDraggingSource {
    private weak var activeContextMenu: NSMenu?
    private static let copyQueue = DispatchQueue(label: "app.shotpin.copy-loader", qos: .userInitiated)

    let url: URL
    private let imageView = NSImageView()
    private let card = NSView()
    private let closeButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private var hideErrorWorkItem: DispatchWorkItem?
    private var mouseDownPoint: NSPoint?
    private var mouseDownTime: TimeInterval = 0
    private var draggingOut = false
    private var edgeFlick = false
    private var flickStartFrame: NSRect = .zero
    private var flickStartScreen: NSPoint = .zero
    private var flickDirection: PinPlacement = .right
    private var flickDistance: CGFloat = 0
    private var flickThreshold: CGFloat = 45
    private var movedWhilePressed = false
    private var pendingShare: DispatchWorkItem?
    private let gestureHint = GestureHint()
    private var holdRing: CAShapeLayer?
    private var longPressTimer: Timer?
    private var didLongPress = false
    private var loadedModificationDate: Date?
    private var isHovering = false
    weak var panel: PinPanel?

    init(url: URL, image: NSImage, cardSize: NSSize) {
        self.url = url
        self.loadedModificationDate = (try? shotFileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let total = NSSize(width: cardSize.width + Style.padding * 2,
                           height: cardSize.height + Style.padding * 2)
        super.init(frame: NSRect(origin: .zero, size: total))
        wantsLayer = true

        card.frame = NSRect(x: Style.padding, y: Style.padding,
                            width: cardSize.width, height: cardSize.height)
        addSubview(card)
        card.wantsLayer = true
        if let layer = card.layer {
            layer.cornerRadius = Style.corner
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
            layer.masksToBounds = false
            let shadow = CALayer()
            shadow.frame = card.bounds
            shadow.cornerRadius = Style.corner
            shadow.backgroundColor = NSColor.windowBackgroundColor.cgColor
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0.18
            shadow.shadowRadius = 6
            shadow.shadowOffset = CGSize(width: 0, height: -2)
            shadow.shadowPath = CGPath(roundedRect: card.bounds,
                                      cornerWidth: Style.corner,
                                      cornerHeight: Style.corner,
                                      transform: nil)
            layer.addSublayer(shadow)
        }
        imageView.frame = card.bounds
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Style.corner
        imageView.layer?.masksToBounds = true
        card.addSubview(imageView)

        errorLabel.alignment = .center
        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .white
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.frame = NSRect(x: 6, y: 6, width: card.bounds.width - 12, height: 34)
        errorLabel.wantsLayer = true
        errorLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        errorLabel.layer?.cornerRadius = 5
        errorLabel.isHidden = true
        card.addSubview(errorLabel)

        // ✕ saves the screenshot into the folder the user picked, so the pin is
        // a commit action rather than a delete. Deleting lives in the menu.
        let glyph = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "存储截图")
        closeButton.image = glyph
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = NSColor.systemRed
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.frame = NSRect(x: 0, y: total.height - 26, width: 26, height: 26)
        closeButton.target = self
        closeButton.action = #selector(saveAndDismiss)
        closeButton.toolTip = "关闭并保存截图"
        closeButton.isHidden = true
        addSubview(closeButton)

        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(tracking)
    }

    var stackImage: NSImage? { imageView.image }
    var transitionCardFrame: NSRect { card.frame }

    func containsScreenshotPoint(_ pointInWindow: NSPoint) -> Bool {
        let pointInView = convert(pointInWindow, from: nil)
        return imageView.bounds.contains(imageView.convert(pointInView, from: self))
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// The card and image view are visual-only. Keep the close button interactive,
    /// but route the rest of the thumbnail's mouse sequence through ShotView so its
    /// click and drag handling cannot be swallowed by an NSImageView/NSControl.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        let closePoint = closeButton.convert(point, from: self)
        if !closeButton.isHidden, closeButton.bounds.contains(closePoint) {
            return closeButton
        }
        return self
    }

    /// Hovering is the moment the thumbnail is about to be used, so refresh it
    /// here: an editor such as 预览 may have rewritten the file since it was
    /// pinned, and the pin should show the annotated version.
    override func mouseEntered(with event: NSEvent) {
        let hints = [("didDoubleAnnotate", "双击标注"), ("didHoldPreview", "长按预览")]
            .filter { !UserDefaults.standard.bool(forKey: $0.0) }.map { $0.1 }
        if !hints.isEmpty, let window { gestureHint.show(hints.joined(separator: " · "), beside: window, delay: 0.65) }
        isHovering = true
        animateCardHover(true)
        reloadThumbnail()
    }

    override func mouseExited(with event: NSEvent) {
        gestureHint.hide()
        isHovering = false
        closeButton.isHidden = true
        animateCardHover(false)
    }

    /// A restrained lift makes the hovered screenshot feel active while keeping
    /// the thumbnail in place. Respect the system's Reduce Motion preference.
    private func animateCardHover(_ hovering: Bool) {
        guard let layer = card.layer else { return }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale: CGFloat = hovering && !reducedMotion ? 1.025 : 1
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale")
            ?? layer.value(forKeyPath: "transform.scale") ?? 1
        animation.toValue = scale
        animation.duration = reducedMotion ? 0 : (hovering ? 0.2 : 0.16)
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.setValue(scale, forKeyPath: "transform.scale")
        layer.add(animation, forKey: "shotpin.hover-lift")

        if hovering && !reducedMotion {
            layer.removeAnimation(forKey: "shotpin.hover-settle")
            layer.add(makeIconWiggle(for: layer), forKey: "shotpin.hover-sway")
        } else if !reducedMotion, layer.animation(forKey: "shotpin.hover-sway") != nil {
            let current = layer.presentation()
            let angle = current?.value(forKeyPath: "transform.rotation.z") as? NSNumber ?? 0
            let offset = NSPoint(x: (current?.position.x ?? layer.position.x) - layer.position.x,
                                 y: (current?.position.y ?? layer.position.y) - layer.position.y)
            layer.removeAnimation(forKey: "shotpin.hover-sway")
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = angle
            rotation.toValue = 0
            let translation = CABasicAnimation(keyPath: "position")
            translation.isAdditive = true
            translation.fromValue = NSValue(point: offset)
            translation.toValue = NSValue(point: .zero)
            let settle = CAAnimationGroup()
            settle.animations = [rotation, translation]
            settle.duration = 0.22
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(settle, forKey: "shotpin.hover-settle")
        } else {
            layer.removeAnimation(forKey: "shotpin.hover-sway")
            layer.removeAnimation(forKey: "shotpin.hover-settle")
        }
    }

    @objc private func dismissPin() {
        saveScreenshot(sliding: nil)
    }

    // MARK: click to open, drag to hand the file to another app

    override func mouseDown(with event: NSEvent) {
        gestureHint.hide()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(collapseAfterClick), object: nil)
        mouseDownTime = event.timestamp
        mouseDownPoint = event.locationInWindow
        flickStartFrame = window?.frame ?? .zero
        flickStartScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        flickDirection = PinPlacement.current
        flickDistance = 0
        flickThreshold = 45
        if flickDirection == .top, let screen = window?.screen {
            // Near the menu bar the pointer cannot travel a full 45 points.
            flickThreshold = max(6, min(35, screen.frame.maxY - flickStartScreen.y - 2))
        }
        draggingOut = false
        edgeFlick = false
        movedWhilePressed = false
        pendingShare?.cancel()
        didLongPress = false
        holdRing?.removeFromSuperlayer()
        longPressTimer?.invalidate()
        guard event.clickCount == 1 else { return }
        let ring = CAShapeLayer()
        let point = convert(event.locationInWindow, from: nil)
        ring.path = CGPath(ellipseIn: CGRect(x: point.x + 5, y: point.y + 5, width: 14, height: 14), transform: nil)
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.fillColor = nil
        ring.lineWidth = 2
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = 0.5
        layer?.addSublayer(ring)
        ring.add(fill, forKey: "holdProgress")
        holdRing = ring
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.mouseDownPoint != nil, !self.draggingOut,
                  self.window?.isVisible == true else { return }
            self.didLongPress = true
            self.longPressTimer = nil
            self.holdRing?.removeFromSuperlayer()
            UserDefaults.standard.set(true, forKey: "didHoldPreview")
            self.toolTip = nil
            ShotQuickLook.shared.show(self.url)
        }
        longPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !draggingOut, !didLongPress else { return }
        let now = event.locationInWindow
        if edgeFlick {
            updateFlickPosition(event)
            return
        }
        if abs(now.x - start.x) < 4 && abs(now.y - start.y) < 4 { return }
        movedWhilePressed = true
        holdRing?.removeFromSuperlayer()
        longPressTimer?.invalidate()
        longPressTimer = nil
        let dx = now.x - start.x
        let dy = now.y - start.y
        let along: CGFloat
        let across: CGFloat
        switch flickDirection {
        case .right: along = dx; across = abs(dy)
        case .left: along = -dx; across = abs(dy)
        case .top: along = dy; across = abs(dx)
        }
        let elapsed = max(0.001, event.timestamp - mouseDownTime)
        if along >= flickThreshold && along > across * 1.3 && elapsed < 0.35 {
            pendingShare?.cancel()
            pendingShare = nil
            edgeFlick = true
            updateFlickPosition(event)
            return
        }
        if along > 0 && along > across * 1.3 && elapsed < 0.22 {
            pendingShare?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.beginShareDrag(event) }
            pendingShare = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 - elapsed, execute: work)
            return
        }
        pendingShare?.cancel()
        pendingShare = nil
        beginShareDrag(event)
    }

    private func updateFlickPosition(_ event: NSEvent) {
        guard let window else { return }
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        let dx = cursor.x - flickStartScreen.x
        let dy = cursor.y - flickStartScreen.y
        var origin = flickStartFrame.origin
        switch flickDirection {
        case .right:
            flickDistance = max(0, dx)
            origin.x += flickDistance
        case .left:
            flickDistance = max(0, -dx)
            origin.x -= flickDistance
        case .top:
            flickDistance = max(0, dy)
            origin.y += flickDistance
        }
        window.setFrameOrigin(origin)
    }

    private func restoreFlickPosition() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrameOrigin(flickStartFrame.origin)
        }
    }

    private func beginShareDrag(_ event: NSEvent) {
        guard mouseDownPoint != nil, !draggingOut, !edgeFlick, !didLongPress else { return }
        draggingOut = true

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragImage = imageView.image ?? NSImage(size: card.bounds.size)
        item.setDraggingFrame(card.frame, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingShare?.cancel()
        pendingShare = nil
        holdRing?.removeFromSuperlayer()
        longPressTimer?.invalidate()
        longPressTimer = nil
        let wasFlick = edgeFlick && !draggingOut
        if wasFlick { updateFlickPosition(event) }
        let shouldSave = wasFlick && flickDistance >= flickThreshold
        let shouldOpen = !movedWhilePressed && !edgeFlick && !draggingOut && !didLongPress && event.timestamp - mouseDownTime < 0.3 && bounds.contains(point)
        mouseDownPoint = nil
        draggingOut = false
        edgeFlick = false
        if wasFlick {
            if !shouldSave || !saveScreenshot(sliding: flickDirection) { restoreFlickPosition() }
            return
        }
        if shouldOpen {
            if event.clickCount >= 2 {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(collapseAfterClick), object: nil)
                UserDefaults.standard.set(true, forKey: "didDoubleAnnotate")
                toolTip = nil
                annotate()
            } else {
                perform(#selector(collapseAfterClick), with: nil, afterDelay: min(NSEvent.doubleClickInterval, 0.12))
            }
        }
    }

    @objc private func collapseAfterClick() {
        PinManager.shared.collapse()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // AppKit may end the dragging session before delivering the source
        // view's mouseUp. Keep the flag set so that mouseUp cannot interpret
        // the completed drag as a click and open the screenshot.
    }

    // MARK: context menu

    override func rightMouseDown(with event: NSEvent) {
        gestureHint.hide()
        presentMenu(event, anchor: self, stacked: false)
    }

    func presentMenu(_ event: NSEvent, anchor: NSView, stacked: Bool) {
        let menu = NSMenu()
        menu.addItem(withTitle: stacked ? "展开全部截图" : "收起全部截图", action: #selector(collapseAll), keyEquivalent: "")
        let placementItem = NSMenuItem(title: "截图排列位置", action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        for placement in PinPlacement.allCases {
            let item = NSMenuItem(title: placement.title, action: #selector(changePlacement(_:)), keyEquivalent: "")
            item.representedObject = placement.rawValue
            item.target = self
            item.state = placement == PinPlacement.current ? .on : .off
            placementMenu.addItem(item)
        }
        placementItem.submenu = placementMenu
        if stacked {
            menu.addItem(placementItem)
            menu.addItem(.separator())
            for (title, selector, enabled) in [("自动拷贝", #selector(toggleAutoCopy), UserDefaults.standard.bool(forKey: "autoCopyNewShot")),
                                                ("全屏自动隐藏", #selector(toggleFullscreenAutoHide), AppDelegate.fullscreenAutoHideEnabled),
                                                ("悬停自动展开", #selector(toggleAutoExpand), PinManager.autoExpandEnabled),
                                                ("双击 Command 展开或收起", #selector(toggleCommandExpand), UserDefaults.standard.bool(forKey: "commandExpandStack"))] {
                let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: enabled ? "✓" : "")
                item.keyEquivalentModifierMask = []
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "选择存储文件夹…", action: #selector(chooseSaveFolder), keyEquivalent: "")
            menu.addItem(withTitle: "打开存储文件夹", action: #selector(openSaveFolder), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 BetterShot", action: #selector(quitApp), keyEquivalent: "")
            for item in menu.items where item.action != nil { item.target = self }
            activeContextMenu = menu
            PinManager.shared.menuTracking = true
            NSMenu.popUpContextMenu(menu, with: event, for: anchor)
            PinManager.shared.menuTracking = false
            activeContextMenu = nil
            return
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开", action: #selector(openFile), keyEquivalent: "")
        let annotateItem = menu.addItem(withTitle: "标注", action: #selector(annotate), keyEquivalent: "")
        let preview = menu.addItem(withTitle: "预览", action: #selector(previewShot), keyEquivalent: "")
        addMenuHint("双击", to: annotateItem)
        addMenuHint("长按", to: preview)
        menu.addItem(withTitle: "拷贝图像", action: #selector(copyImage), keyEquivalent: "")
        let airDropItem = menu.addItem(withTitle: "隔空投送", action: #selector(airDrop), keyEquivalent: "")
        addMenuHint("Option", to: airDropItem)
        menu.addItem(withTitle: "复制图中文字", action: #selector(copyText), keyEquivalent: "")
        let others = PinManager.shared.shots.filter { $0 !== self }
        if !others.isEmpty {
            let choices = NSMenu()
            for shot in others.reversed() {
                let item = choices.addItem(withTitle: shot.url.lastPathComponent, action: #selector(compareWith(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = shot.url
                item.image = shot.stackImage?.copy() as? NSImage
                item.image?.size = NSSize(width: 28, height: 20)
            }
            let compare = NSMenuItem(title: "与另一张对照", action: nil, keyEquivalent: "")
            compare.submenu = choices
            menu.addItem(compare)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "删除截图", action: #selector(trashFile), keyEquivalent: "")
        let slideHint: String
        switch PinPlacement.current {
        case .right: slideHint = "按住右滑"
        case .left: slideHint = "按住左滑"
        case .top: slideHint = "按住上滑"
        }
        let closeItem = menu.addItem(withTitle: "关闭此图窗", action: #selector(dismissPin), keyEquivalent: "")
        addMenuHint(slideHint, to: closeItem)
        menu.addItem(withTitle: "关闭全部图窗", action: #selector(dismissAll), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        activeContextMenu = menu
        PinManager.shared.menuTracking = true
        NSMenu.popUpContextMenu(menu, with: event, for: anchor)
        PinManager.shared.menuTracking = false
        activeContextMenu = nil
    }

    private func addMenuHint(_ hint: String, to item: NSMenuItem) {
        if #available(macOS 14.0, *) {
            item.badge = NSMenuItemBadge(string: hint)
            return
        }
        let titleFont = NSFont.menuFont(ofSize: 0)
        let hintFont = NSFont.menuFont(ofSize: titleFont.pointSize - 2)
        let hintWidth = ceil((hint as NSString).size(withAttributes: [.font: hintFont]).width)
        // Position the start of each hint so that all hints end at the same point.
        // A right tab makes AppKit reserve the hint width again when sizing the menu.
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 150 - hintWidth)]
        let title = NSMutableAttributedString(string: item.title + "\t", attributes: [
            .font: titleFont,
            .paragraphStyle: style
        ])
        title.append(NSAttributedString(string: hint, attributes: [
            .font: hintFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ]))
        item.attributedTitle = title
    }

    @objc private func compareWith(_ sender: NSMenuItem) {
        if let other = sender.representedObject as? URL { Comparison.shared.show([url, other]) }
    }

    @objc private func copyText() {
        let file = url
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            do {
                try VNImageRequestHandler(url: file).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                DispatchQueue.main.async {
                    guard !text.isEmpty else { self.showError("未识别到文字"); return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            } catch { DispatchQueue.main.async { self.showError("无法识别这张图片") } }
        }
    }
    @objc func airDrop() {
        guard shotFileManager.fileExists(atPath: url.path),
              let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            showError("无法打开隔空投送")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }
    @objc private func previewShot() { ShotQuickLook.shared.show(url) }
    @objc private func collapseAll() { PinManager.shared.toggleStack() }
    @objc private func toggleAutoExpand() { PinManager.shared.toggleAutoExpand() }
    @objc private func toggleCommandExpand() { (NSApp.delegate as? AppDelegate)?.toggleCommandExpand() }
    @objc private func changePlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let placement = PinPlacement(rawValue: raw) else { return }
        PinPlacement.current = placement
        PinManager.shared.animatePlacement()
    }

    @objc private func openFile() {
        guard shotFileManager.fileExists(atPath: url.path) else {
            showError("文件已不存在")
            return
        }
        if !NSWorkspace.shared.open(url) {
            showError("无法打开截图")
        }
    }

    @objc private func toggleAutoCopy() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "autoCopyNewShot"), forKey: "autoCopyNewShot")
        activeContextMenu?.cancelTracking()
    }

    static func copyImage(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        copyQueue.async {
            let contentType = UTType(filenameExtension: url.pathExtension)
            let data = contentType.flatMap { type in
                (type.conforms(to: .image) || type.conforms(to: .pdf)) ? try? Data(contentsOf: url, options: .mappedIfSafe) : nil
            }
            DispatchQueue.main.async {
                guard let contentType, let data else {
                    NSLog("BetterShot: could not read image for clipboard")
                    completion?(false); return
                }
                let item = NSPasteboardItem()
                guard item.setData(data, forType: NSPasteboard.PasteboardType(contentType.identifier)) else {
                    NSLog("BetterShot: could not prepare image for clipboard")
                    completion?(false); return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let success = pasteboard.writeObjects([item])
                if !success { NSLog("BetterShot: could not write image to clipboard") }
                completion?(success)
            }
        }
    }

    @objc private func copyImage() {
        Self.copyImage(url) { [weak self] success in
            if !success { self?.showError("无法复制截图") }
        }
    }

    @objc private func revealInFinder() {
        guard shotFileManager.fileExists(atPath: url.path) else {
            showError("文件已不存在")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Commit the pin: move the file out of the private workspace into the
    /// folder chosen by the user, then drop the pin. The first use asks for a
    /// folder; a folder that later disappears asks again.
    @objc private func saveAndDismiss() {
        saveScreenshot(sliding: nil)
    }

    @discardableResult
    private func saveScreenshot(sliding direction: PinPlacement?) -> Bool {
        do {
            let destination = try SaveDestination.save(url)
            NSLog("ShotPin: saved %@", destination.path)
            if let panel { PinManager.shared.rememberClosed(destination, screen: panel.targetDisplayID) }
            if let panel { PinManager.shared.remove(panel, sliding: direction, remember: false) }
            return true
        } catch SaveDestination.SaveError.cancelled {
            return false
        } catch {
            showError("无法保存截图")
            return false
        }
    }

    /// ShotPin's own canvas: the marks are baked into the screenshot's file in
    /// place, so the pin keeps pointing at one file that can still be dragged out
    /// with the annotations on it.
    @objc private func annotate() {
        AnnotationController.shared.present(url: url)
    }

    @objc private func chooseSaveFolder() {
        guard let folder = SaveDestination.chooseFolder(startingAt: SaveDestination.folder) else {
            return
        }
        showToast("存储到：\(folder.lastPathComponent)")
    }

    @objc private func openSaveFolder() {
        guard SaveDestination.folder != nil else {
            if SaveDestination.chooseFolder(startingAt: nil) != nil {
                SaveDestination.revealFolder()
            }
            return
        }
        SaveDestination.revealFolder()
    }

    private func showToast(_ message: String) {
        showError(message)
    }

    /// Re-read the thumbnail when the file changed on disk (for example after it
    /// was annotated in 预览). Unchanged files are skipped so hovering is cheap.
    func reloadThumbnail(force: Bool = false) {
        let modified = (try? shotFileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if !force, let modified, let loaded = loadedModificationDate, modified <= loaded {
            return
        }
        ThumbnailLoader.load(url) { [weak self] image in
            guard let self else { return }
            self.loadedModificationDate = modified
            guard let image else {
                self.showError("无法刷新截图")
                return
            }
            self.imageView.image = image
        }
    }

    @objc private func trashFile() {
        do {
            try shotFileManager.trashItem(at: url, resultingItemURL: nil)
            if let panel { PinManager.shared.remove(panel, trashing: true, remember: false) }
        } catch {
            showError("无法移到废纸篓")
        }
    }

    fileprivate func reportSaveFailure() {
        if window?.isVisible == true { showError("无法保存截图") }
        else {
            let alert = NSAlert()
            alert.messageText = "无法保存截图"
            alert.informativeText = "未保存的截图仍保留在图窗中，请检查存储文件夹后重试。"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func showError(_ message: String) {
        hideErrorWorkItem?.cancel()
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        errorLabel.superview?.addSubview(errorLabel, positioned: .above, relativeTo: nil)

        let workItem = DispatchWorkItem { [weak self] in
            self?.errorLabel.isHidden = true
        }
        hideErrorWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    @objc private func dismissAll() { PinManager.shared.dismissAll() }

    @objc private func toggleFullscreenAutoHide() {
        (NSApp.delegate as? AppDelegate)?.toggleFullscreenAutoHide()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Floating panel

final class PinPanel: NSPanel {
    var targetDisplayID: CGDirectDisplayID

    init(url: URL, image: NSImage, screen: NSScreen) {
        self.targetDisplayID = screen.displayID

        var fit = image.size
        if fit.width <= 0 || fit.height <= 0 { fit = NSSize(width: 160, height: 100) }
        let scale = min(Style.maxDimension / fit.width, Style.maxDimension / fit.height, 1.0)
        let cardSize = NSSize(width: max(60, (fit.width * scale).rounded()),
                              height: max(48, (fit.height * scale).rounded()))
        let total = NSSize(width: cardSize.width + Style.padding * 2,
                           height: cardSize.height + Style.padding * 2)

        super.init(contentRect: NSRect(origin: .zero, size: total),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        // No .stationary and a floating level: those two are what kept pins
        // glued on screen during 显示桌面 / 调度中心. Staying at .floating keeps
        // them above app windows while letting the system sweep them away.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        sharingType = .readOnly

        let view = ShotView(url: url, image: image, cardSize: cardSize)
        view.panel = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Stack of pins

final class PinManager {
    static let shared = PinManager()
    static var autoExpandEnabled: Bool { UserDefaults.standard.bool(forKey: "hoverExpandStack") }
    private var panels: [PinPanel] = []
    private(set) var screenshotsHidden = false
    private(set) var manuallyHidden = false
    private var fullscreenHidden = false
    private(set) var hidingAnimation = false
    private var visibilityOverlay: NSPanel?
    private var visibilityLayers: [ObjectIdentifier: CALayer] = [:]
    private var departureCount = 0
    private var departureLayout: [PinPanel]?

    func toggleHidden(iconFrame: NSRect?) {
        guard !hidingAnimation else { return }
        manuallyHidden.toggle()
        updateVisibility(iconFrame: iconFrame)
    }

    func setFullscreenHidden(_ hidden: Bool, iconFrame: NSRect?) {
        fullscreenHidden = hidden
        if hidden { ScreenshotTransitions.hideOverlays() }
        updateVisibility(iconFrame: iconFrame, fullscreenTransition: true)
    }

    private func orderScreenshots(_ visible: Bool) {
        if !visible {
            stackPanel?.orderOut(nil)
            panels.forEach { $0.orderOut(nil) }
        } else if let stack = stackPanel {
            stack.ignoresMouseEvents = false
            stack.orderFrontRegardless()
        } else {
            layout()
            for panel in panels {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }
    }

    private func updateVisibility(iconFrame: NSRect?, fullscreenTransition: Bool = false) {
        let hidden = manuallyHidden || fullscreenHidden
        let hideImmediately = fullscreenTransition && hidden
        guard hidden != screenshotsHidden || (hideImmediately && visibilityOverlay != nil) else { return }
        let showing = !hidden
        screenshotsHidden = hidden
        automaticallyExpanded = false
        hoverStarted = nil
        awayStarted = nil
        stackHint.hide()
        let interrupted = visibilityOverlay != nil
        var startingFrames: [ObjectIdentifier: (frame: CGRect, opacity: Float)] = [:]
        if let previous = visibilityOverlay {
            for (id, layer) in visibilityLayers where !hideImmediately {
                let current = layer.presentation() ?? layer
                startingFrames[id] = (current.frame.offsetBy(dx: previous.frame.minX, dy: previous.frame.minY),
                                      current.opacity)
            }
            previous.orderOut(nil)
        }
        visibilityOverlay = nil
        visibilityLayers.removeAll()
        hidingAnimation = false
        if hideImmediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orderScreenshots(showing)
            return
        }
        if showing && stackPanel == nil { layout() }
        let targets: [NSWindow] = stackPanel.map { [$0] } ?? panels.filter { showing || interrupted || $0.isVisible }.map { $0 as NSWindow }
        guard !targets.isEmpty else { return }
        let screens = NSScreen.screens
        guard let firstScreen = screens.first else { orderScreenshots(showing); return }
        let menuBarHeight = NSStatusBar.system.thickness
        let anchor = iconFrame ?? NSRect(x: firstScreen.frame.midX - 10,
                                        y: firstScreen.frame.maxY - menuBarHeight, width: 20, height: menuBarHeight)
        let largestWidth = targets.map { $0.frame.width }.max() ?? anchor.width
        let largestHeight = targets.map { $0.frame.height }.max() ?? anchor.height
        // A full-size card reaches the icon before shrinking, so leave room
        // around the anchor even when it lies outside the column of pins.
        let gatheringArea = anchor.insetBy(dx: -largestWidth / 2, dy: -largestHeight / 2)
        let initialBounds = startingFrames.values.reduce(gatheringArea) { $0.union($1.frame) }
        let desktop = screens.dropFirst().reduce(firstScreen.frame) { $0.union($1.frame) }
        let requestedBounds = targets.reduce(initialBounds) { $0.union($1.frame) }
            .insetBy(dx: -12, dy: -12).intersection(desktop)
        guard !requestedBounds.isEmpty else { orderScreenshots(showing); return }
        let overlay = NSPanel(contentRect: requestedBounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Draw over the menu bar so it cannot mask the middle of the gather
        // or the final shrink at the status icon.
        overlay.level = fullscreenTransition ? .floating : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        overlay.setFrame(requestedBounds, display: false)
        let screenBounds = overlay.frame
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.sharingType = .readOnly
        let canvas = NSView(frame: NSRect(origin: .zero, size: screenBounds.size))
        canvas.wantsLayer = true
        overlay.contentView = canvas
        let duration: CFTimeInterval = showing ? 0.46 : ScreenshotTransitions.hideDuration
        var layers: [(CALayer, [CGRect], Float)] = []
        let gatherCenter = NSPoint(
            x: anchor.midX - screenBounds.minX,
            y: anchor.midY - screenBounds.minY
        )
        for window in targets {
            let id = ObjectIdentifier(window)
            let start = startingFrames[id]
            guard let view = window.contentView else { continue }
            let image: CGImage
            let cardFrame: NSRect
            let usesThumbnail: Bool
            if fullscreenTransition, let shot = view as? ShotView,
               let thumbnail = shot.stackImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // The pin already has a decoded thumbnail. Avoid drawing a live AppKit
                // window into a bitmap while the system compositor changes Spaces.
                image = thumbnail
                cardFrame = shot.transitionCardFrame
                usesThumbnail = true
            } else {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let snapshot = bitmap.cgImage else { continue }
                image = snapshot
                cardFrame = view.bounds
                usesThumbnail = false
            }
            let original = cardFrame.offsetBy(dx: window.frame.minX - screenBounds.minX,
                                               dy: window.frame.minY - screenBounds.minY)
            let factor = min(anchor.width / max(original.width, 1), anchor.height / max(original.height, 1))
            let smallSize = NSSize(width: max(1, original.width * factor), height: max(1, original.height * factor))
            let small = CGRect(x: gatherCenter.x - smallSize.width / 2, y: gatherCenter.y - smallSize.height / 2, width: smallSize.width, height: smallSize.height)
            let gathered = CGRect(x: gatherCenter.x - original.width / 2, y: gatherCenter.y - original.height / 2,
                                  width: original.width, height: original.height)
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = usesThumbnail ? .resizeAspect : .resize
            if usesThumbnail {
                layer.cornerRadius = Style.corner
                layer.masksToBounds = true
            }
            let startFrame = start?.frame.offsetBy(dx: -screenBounds.minX, dy: -screenBounds.minY)
            let frames = showing ? [startFrame ?? small, original] : [startFrame ?? original, gathered, small]
            let initialOpacity = start?.opacity ?? (showing ? 0 : 1)
            layer.frame = frames[0]
            layer.opacity = initialOpacity
            canvas.layer?.addSublayer(layer)
            visibilityLayers[id] = layer
            layers.append((layer, frames, initialOpacity))
        }
        guard !layers.isEmpty else { orderScreenshots(showing); return }
        visibilityOverlay = overlay
        hidingAnimation = true
        overlay.orderFrontRegardless()
        targets.forEach { $0.orderOut(nil) }
        if fullscreenTransition {
            waitForVisibilityOverlay(overlay) { [weak self] in
                self?.animateVisibility(in: overlay, layers: layers, showing: showing,
                                        duration: duration)
            }
        } else {
            animateVisibility(in: overlay, layers: layers, showing: showing,
                              duration: duration)
        }
    }

    // Space transitions can take the window out of the compositor while its
    // Core Animation clock keeps running. Hold the first frame until the
    // overlay has been visible on the destination Space across two refreshes.
    private func waitForVisibilityOverlay(_ overlay: NSPanel, completion: @escaping () -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.23
        let rate = overlay.screen?.maximumFramesPerSecond ?? 60
        let interval = 1.0 / Double(max(60, rate))
        func check(_ visibleFrames: Int) {
            guard self.visibilityOverlay === overlay else { return }
            let visible = overlay.isOnActiveSpace && overlay.occlusionState.contains(.visible)
            let frames = visible ? visibleFrames + 1 : 0
            if frames >= 2 || ProcessInfo.processInfo.systemUptime >= deadline {
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check(frames) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check(0) }
    }

    private func animateVisibility(in overlay: NSPanel, layers: [(CALayer, [CGRect], Float)],
                                   showing: Bool, duration: CFTimeInterval) {
        guard visibilityOverlay === overlay else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            self.finishVisibility(in: overlay, showing: showing)
        }
        for (layer, frames, initialOpacity) in layers {
            if let finalFrame = frames.last { layer.frame = finalFrame }
            layer.opacity = showing ? 1 : 0
            let position = CAKeyframeAnimation(keyPath: "position")
            let size = CAKeyframeAnimation(keyPath: "bounds")
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            position.values = frames.map { NSValue(point: NSPoint(x: $0.midX, y: $0.midY)) }
            size.values = frames.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) }
            opacity.values = showing ? [initialOpacity, 1] : [initialOpacity, 1, 1, 0]
            if !showing {
                position.keyTimes = [0, 0.4, 1]
                size.keyTimes = [0, 0.4, 1]
                opacity.keyTimes = [0, 0.4, 0.72, 1]
                let easing = CAMediaTimingFunction(name: .easeInEaseOut)
                position.timingFunctions = [easing, easing]
                size.timingFunctions = [easing, easing]
                opacity.timingFunctions = [easing, easing, easing]
            }
            let group = CAAnimationGroup()
            position.duration = duration
            size.duration = duration
            opacity.duration = duration
            group.animations = [position, size, opacity]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: showing ? .easeInEaseOut : .linear)
            layer.add(group, forKey: "visibility")
        }
        CATransaction.commit()
    }

    private func finishVisibility(in overlay: NSPanel, showing: Bool) {
        guard visibilityOverlay === overlay else { overlay.orderOut(nil); return }
        visibilityOverlay = nil
        visibilityLayers.removeAll()
        if showing && !screenshotsHidden { orderScreenshots(true) }
        overlay.orderOut(nil)
        hidingAnimation = false
    }

    var shots: [ShotView] { panels.compactMap { $0.contentView as? ShotView } }
    private var page = 0
    var latestShot: ShotView? { panels.last?.contentView as? ShotView }
    var topShot: ShotView? { panels.reversed().dropFirst(page).first?.contentView as? ShotView }
    func flip(_ step: Int) {
        guard panels.count > 1 else { return }
        page = (page + step + panels.count) % panels.count
        waitForStackExit = true
        hoverStarted = nil
        updateStack()
    }
    private var closed: [[(URL, CGDirectDisplayID)]] = []
    private var reopening = false
    var canReopen: Bool {
        !reopening && closed.contains { group in group.contains { shotFileManager.fileExists(atPath: $0.0.path) } }
    }
    func reopen() {
        guard !reopening, let workspace = CaptureWorkspace.shared.directory else { return }
        guard let group = closed.popLast() else { return }
        reopening = true
        var failed: [(URL, CGDirectDisplayID)] = []
        func restore(_ index: Int) {
            guard index < group.count else {
                if !failed.isEmpty { self.closed.append(failed); NSSound.beep() }
                self.reopening = false
                return
            }
            let (url, screen) = group[index]
            guard shotFileManager.fileExists(atPath: url.path), !PendingPins.contains(url) else {
                restore(index + 1)
                return
            }
            var pinURL = url
            let copied = url.deletingLastPathComponent().standardizedFileURL != workspace.standardizedFileURL
            if copied {
                pinURL = SaveDestination.uniqueDestination(for: url.lastPathComponent, in: workspace)
                do { try shotFileManager.copyItem(at: url, to: pinURL) }
                catch { failed.append((url, screen)); restore(index + 1); return }
            }
            ThumbnailLoader.load(pinURL) { image in
                if let image {
                    self.add(url: pinURL, image: image, targetDisplayID: screen)
                } else {
                    if copied { try? shotFileManager.removeItem(at: pinURL) }
                    failed.append((url, screen))
                }
                restore(index + 1)
            }
        }
        restore(0)
    }
    func rememberClosed(_ url: URL, screen: CGDirectDisplayID) {
        closed.append([(url, screen)])
    }
    func airDropAtPointer() {
        let point = NSEvent.mouseLocation
        guard stackPanel == nil,
              let panel = panels.reversed().first(where: { $0.isVisible && $0.frame.contains(point) }),
              let shot = panel.contentView as? ShotView,
              shot.containsScreenshotPoint(panel.convertPoint(fromScreen: point)) else { return }
        shot.airDrop()
    }
    func restoreWithCommand() {
        guard !screenshotsHidden else { return }
        if let stack = stackPanel {
            guard stack.isVisible, !stack.ignoresMouseEvents else { return }
            restore(automatic: true)
        } else {
            collapse()
        }
    }
    var count: Int { panels.count }
    var collapsed: Bool { stackPanel != nil }
    func toggleStack() { guard !screenshotsHidden else { return }; if collapsed { restore() } else { collapse() } }
    private let stackHint = GestureHint()
    private var stackPanel: NSPanel?
    private var hoverTimer: Timer?
    private var hoverStarted: TimeInterval?
    private var awayStarted: TimeInterval?
    private var automaticallyExpanded = false
    private var waitForStackExit = false
    var menuTracking = false

    private init() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkHover() }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func toggleAutoExpand() {
        UserDefaults.standard.set(!Self.autoExpandEnabled, forKey: "hoverExpandStack")
        hoverStarted = nil
        awayStarted = nil
        if !Self.autoExpandEnabled { automaticallyExpanded = false }
        updateStack()
    }

    private func pointerIsOverScreenshot(_ point: NSPoint) -> Bool {
        panels.contains { panel in
            guard panel.isVisible, let shot = panel.contentView as? ShotView else { return false }
            return shot.containsScreenshotPoint(panel.convertPoint(fromScreen: point))
        }
    }

    func handleOutsideClick() {
        let point = NSEvent.mouseLocation
        guard Self.autoExpandEnabled, automaticallyExpanded, stackPanel == nil, !menuTracking,
              !panels.contains(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
        awayStarted = nil
        automaticallyExpanded = false
        waitForStackExit = true
        collapse()
    }

    private func checkHover() {
        guard Self.autoExpandEnabled, !screenshotsHidden else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        guard NSEvent.pressedMouseButtons == 0, !menuTracking else {
            hoverStarted = nil
            awayStarted = nil
            return
        }
        if let stack = stackPanel, stack.isVisible, !stack.ignoresMouseEvents {
            guard Self.autoExpandEnabled else { return }
            let inside = stack.frame.contains(mouse)
            if waitForStackExit {
                if !inside { waitForStackExit = false }
                hoverStarted = nil
                return
            }
            guard inside else { hoverStarted = nil; return }
            if hoverStarted == nil { hoverStarted = now }
            if let start = hoverStarted, now - start >= 0.45 {
                hoverStarted = nil
                restore(automatic: true)
            }
        } else if automaticallyExpanded, stackPanel == nil {
            // Only the visible screenshot itself pauses the collapse timer.
            if pointerIsOverScreenshot(mouse) {
                awayStarted = nil
                return
            }
            if awayStarted == nil { awayStarted = now }
            if let start = awayStarted, now - start >= 1.2 {
                awayStarted = nil
                automaticallyExpanded = false
                waitForStackExit = true
                collapse()
            }
        }
    }
    func add(url: URL, image: NSImage, targetDisplayID: CGDirectDisplayID, arrivalImage: NSImage? = nil, sourceRect: NSRect? = nil) {
        let screen = NSScreen.screens.first(where: { $0.displayID == targetDisplayID })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let panel = PinPanel(url: url, image: image, screen: screen)
        PendingPins.add(url)
        panels.append(panel)
        departureLayout?.append(panel)
        page = 0
        if screenshotsHidden || hidingAnimation {
            if stackPanel != nil { updateStack() } else { layout() }
            return
        }
        if let stack = stackPanel {
            if let arrivalImage, let sourceRect, stack.isVisible {
                let offset = CGFloat(min(2, panels.count - 1)) * 5
                let card = NSRect(x: stack.frame.minX + 5 + offset, y: stack.frame.minY + 5 + offset, width: 86, height: 66)
                let destination = card.insetBy(dx: 1.2, dy: 1.2)
                animateIncoming(image: arrivalImage, start: sourceRect, destination: destination) { [weak self] in
                    self?.updateStack()
                }
            } else { updateStack() }
            return
        }
        panel.alphaValue = 0
        layout()
        if let arrivalImage, let sourceRect, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateIncoming(image: arrivalImage, start: sourceRect, destination: panel.frame.insetBy(dx: Style.padding, dy: Style.padding)) { [weak self, weak panel] in
                guard let self, let panel, self.panels.contains(where: { $0 === panel }), self.stackPanel == nil, !self.screenshotsHidden else { return }
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
            return
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func animateIncoming(image: NSImage, start: NSRect, destination: NSRect, completion: @escaping () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { completion(); return }
        let overlay = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isFloatingPanel = true
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.sharingType = .readOnly
        let view = NSImageView(frame: NSRect(origin: .zero, size: start.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.cornerRadius = 0
        view.layer?.masksToBounds = true
        overlay.contentView = view
        ScreenshotTransitions.trackOverlay(overlay)
        overlay.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            overlay.animator().setFrame(destination, display: true)
        }, completionHandler: {
            ScreenshotTransitions.finishOverlay(overlay)
            completion()
        })
    }

    fileprivate func remove(_ panel: PinPanel, sliding direction: PinPlacement? = nil, trashing: Bool = false, remember: Bool = true) {
        guard let index = panels.firstIndex(of: panel) else { return }
        if departureLayout == nil { departureLayout = panels }
        departureCount += 1
        panels.remove(at: index)
        page = min(page, max(0, panels.count - 1))
        if remember, let shot = panel.contentView as? ShotView, shotFileManager.fileExists(atPath: shot.url.path) { rememberClosed(shot.url, screen: panel.targetDisplayID) }
        if panels.isEmpty {
            stackPanel?.orderOut(nil)
            stackPanel = nil
        } else { updateStack() }
        if let view = panel.contentView as? ShotView { PendingPins.remove(view.url) }
        let finishDeparture = { [weak self] in
            guard let self else { return }
            self.departureCount -= 1
            guard self.departureCount == 0 else { return }
            self.departureLayout = nil
            self.animatePlacement(duration: 0.30)
        }
        guard let direction else {
            if trashing { ScreenshotTransitions.sendToTrash(panel, completion: finishDeparture) }
            else { ScreenshotTransitions.shrink(panel, completion: finishDeparture) }
            return
        }
        ScreenshotTransitions.trackOverlay(panel)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var origin = panel.frame.origin
            switch direction {
            case .left: origin.x -= panel.frame.width * 0.75
            case .right: origin.x += panel.frame.width * 0.75
            case .top: origin.y += panel.frame.height * 0.75
            }
            panel.animator().setFrameOrigin(origin)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            ScreenshotTransitions.finishOverlay(panel)
            finishDeparture()
        })
    }

    /// Refresh the thumbnail of any pin showing this file after its bytes were
    /// rewritten in place by the annotation canvas.
    func reload(url: URL) {
        let normalized = url.standardizedFileURL
        for panel in panels {
            guard let view = panel.contentView as? ShotView,
                  view.url.standardizedFileURL == normalized else { continue }
            view.reloadThumbnail(force: true)
        }
    }

    func dismissAll() {
        automaticallyExpanded = false
        hoverStarted = nil
        awayStarted = nil
        var saved: [(URL, CGDirectDisplayID)] = []
        for panel in panels {
            guard let shot = panel.contentView as? ShotView else { continue }
            do {
                let destination = try SaveDestination.save(shot.url)
                saved.append((destination, panel.targetDisplayID))
                remove(panel, remember: false)
            } catch SaveDestination.SaveError.cancelled {
                break
            } catch {
                shot.reportSaveFailure()
                break
            }
        }
        if !saved.isEmpty { closed.append(saved) }
    }

    func collapse() {
        guard !screenshotsHidden, !panels.isEmpty, stackPanel == nil else { return }
        automaticallyExpanded = false
        awayStarted = nil
        let screen = NSScreen.screens.first(where: { $0.displayID == StackCorner.displayID })
            ?? panels.last?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let size = NSSize(width: 106, height: 90)
        let x = StackCorner.left ? area.minX + 18 : area.maxX - size.width - 18
        let y = StackCorner.bottom ? area.minY + 18 : area.maxY - size.height - 18
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let stack = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stack.isFloatingPanel = true
        stack.level = .floating
        stack.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        stack.backgroundColor = .clear
        stack.isOpaque = false
        stack.hasShadow = false
        stack.hidesOnDeactivate = false
        stack.sharingType = .readOnly
        stack.contentView = CollapsedStackView(frame: NSRect(origin: .zero, size: frame.size))
        stackPanel = stack
        updateStack()
        stack.ignoresMouseEvents = true
        animateTransition(stack: stack, expanding: false)
    }

    private func updateStack() {
        guard let view = stackPanel?.contentView as? CollapsedStackView else { return }
        let ordered = Array(panels.reversed())
        view.images = (0..<min(3, ordered.count)).reversed().compactMap {
            (ordered[(page + $0) % ordered.count].contentView as? ShotView)?.stackImage
        }
        view.page = page
        view.toolTip = Self.autoExpandEnabled ? "停留展开 · 拖动换角" : "单击展开 · 拖动换角"
        view.count = panels.count
        view.needsDisplay = true
    }

    func restore(automatic: Bool = false) {
        guard !screenshotsHidden, let stack = stackPanel, let screen = stack.screen ?? NSScreen.main else { return }
        stackHint.hide()
        automaticallyExpanded = automatic && Self.autoExpandEnabled
        awayStarted = nil
        for panel in panels { panel.targetDisplayID = screen.displayID }
        layout()
        stack.ignoresMouseEvents = true
        animateTransition(stack: stack, expanding: true)
    }

    private func animateTransition(stack: NSPanel, expanding: Bool) {
        let transitioning = panels
        let screens = NSScreen.screens
        guard let first = screens.first else { return }
        let bounds = screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let overlay = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isFloatingPanel = true
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.sharingType = .readOnly
        let canvas = NSView(frame: NSRect(origin: .zero, size: bounds.size))
        canvas.wantsLayer = true
        overlay.contentView = canvas
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.32
        var animations: [(CALayer, CGRect, CGRect)] = []
        let firstVisible = max(0, transitioning.count - 3)
        for (index, panel) in transitioning.enumerated() {
            guard let image = (panel.contentView as? ShotView)?.stackImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let layer = CALayer()
            layer.contents = cgImage
            // Match the stack's stretched thumbnail, so no background bands
            // appear as the card changes aspect ratio during the transition.
            layer.contentsGravity = .resize
            layer.backgroundColor = NSColor.clear.cgColor
            layer.cornerRadius = 9
            layer.masksToBounds = true
            let offset = CGFloat(max(0, index - firstVisible)) * 5
            let small = CGRect(x: stack.frame.minX - bounds.minX + 5 + offset,
                               y: stack.frame.minY - bounds.minY + 5 + offset,
                               width: 86, height: 66)
            let large = panel.frame.insetBy(dx: Style.padding, dy: Style.padding)
                .offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let from = expanding ? small : large
            let to = expanding ? large : small
            layer.frame = to
            canvas.layer?.addSublayer(layer)
            animations.append((layer, from, to))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            if self.screenshotsHidden {
                for panel in transitioning { panel.orderOut(nil) }
                stack.orderOut(nil)
                if expanding && self.stackPanel === stack { self.stackPanel = nil }
            } else if expanding {
                for panel in transitioning where self.panels.contains(where: { $0 === panel }) {
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
                if self.stackPanel === stack { self.stackPanel = nil }
            } else if self.stackPanel === stack {
                self.updateStack()
                stack.orderFrontRegardless()
                if !UserDefaults.standard.bool(forKey: "didSeeStackHint"), let text = stack.contentView?.toolTip {
                    self.stackHint.show(text, beside: stack, delay: 0) {
                        UserDefaults.standard.set(true, forKey: "didSeeStackHint")
                    }
                }
                stack.ignoresMouseEvents = false
            }
            ScreenshotTransitions.finishOverlay(overlay)
        }
        for (layer, from, to) in animations {
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = CGPoint(x: from.midX, y: from.midY)
            position.toValue = CGPoint(x: to.midX, y: to.midY)
            let size = CABasicAnimation(keyPath: "bounds")
            size.fromValue = CGRect(origin: .zero, size: from.size)
            size.toValue = CGRect(origin: .zero, size: to.size)
            let animation = CAAnimationGroup()
            animation.animations = [position, size]
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "transition")
            if !expanding && duration > 0 {
                let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                wiggle.values = [0, -0.025, 0.025, 0]
                wiggle.duration = duration
                wiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(wiggle, forKey: "collapse-wiggle")
            }
        }
        ScreenshotTransitions.trackOverlay(overlay)
        overlay.orderFrontRegardless()
        if expanding { stack.orderOut(nil) }
        else { for panel in transitioning { panel.orderOut(nil) } }
        CATransaction.commit()
    }

    /// Fill each column from bottom to top, then continue to the left.
    func animatePlacement(duration: TimeInterval = 0.38) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layout(animated: true)
        }
    }

    func layout(animated: Bool = false) {
        let availableScreens = NSScreen.screens
        guard !availableScreens.isEmpty else { return }
        let fallbackScreen = NSScreen.main ?? availableScreens[0]
        // Reserve a departing card's slot even if a new screenshot arrives during its animation.
        let layoutPanels = departureLayout ?? panels
        for panel in layoutPanels where !availableScreens.contains(where: { $0.displayID == panel.targetDisplayID }) {
            panel.targetDisplayID = fallbackScreen.displayID
        }
        for screen in availableScreens {
            let area = screen.visibleFrame
            let bottom = area.minY + Style.screenMargin
            let top = area.maxY - Style.screenMargin
            let left = area.minX + Style.screenMargin
            let right = area.maxX - Style.screenMargin
            let placement = PinPlacement.current
            var xCursor = placement == .left ? left : right
            var yCursor = placement == .top ? top : bottom
            var lineExtent: CGFloat = 0
            var hasItems = false
            for panel in layoutPanels where panel.targetDisplayID == screen.displayID {
                let size = panel.frame.size
                var x: CGFloat
                var y: CGFloat
                if placement == .top {
                    if hasItems && xCursor - size.width < left {
                        yCursor -= lineExtent + Style.stackSpacing
                        xCursor = right
                        lineExtent = 0
                        hasItems = false
                    }
                    x = max(left, xCursor - size.width)
                    y = max(bottom, yCursor - size.height)
                    xCursor = x - Style.stackSpacing
                    lineExtent = max(lineExtent, size.height)
                } else {
                    if hasItems && yCursor + size.height > top {
                        xCursor += (placement == .left ? 1 : -1) * (lineExtent + Style.stackSpacing)
                        yCursor = bottom
                        lineExtent = 0
                        hasItems = false
                    }
                    x = placement == .left ? min(xCursor, max(left, right - size.width)) : max(left, xCursor - size.width)
                    y = min(yCursor, max(bottom, top - size.height))
                    yCursor = y + size.height + Style.stackSpacing
                    lineExtent = max(lineExtent, size.width)
                }
                hasItems = true
                guard departureLayout == nil || panels.contains(where: { $0 === panel }) else { continue }
                let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
                if animated { panel.animator().setFrame(frame, display: true) }
                else { panel.setFrame(frame, display: true) }
            }
        }
    }

}

final class CollapsedStackView: NSView, NSDraggingSource {
    var images: [NSImage] = []
    var count = 0
    var page = 0
    private var hold: Timer?
    private var holdRing: CAShapeLayer?
    private var draggingImage = false
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var dragOffset = NSPoint.zero
    private var startTime: TimeInterval = 0
    private var moved = false
    private var wiggleStart: CFTimeInterval = 0
    private var wiggleDuration: CFTimeInterval = 0.8

    private func setWiggleSpeed(duration: CFTimeInterval, preservingPhase: Bool = true) {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let phase = preservingPhase && wiggleStart > 0
            ? (now - wiggleStart).truncatingRemainder(dividingBy: wiggleDuration) / wiggleDuration
            : 0
        wiggleDuration = duration
        wiggleStart = now - phase * duration
        let animation = makeIconWiggle(for: layer, duration: duration)
        animation.beginTime = wiggleStart
        layer.add(animation, forKey: "shotpin.stack-wiggle")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.removeAnimation(forKey: "shotpin.stack-wiggle")
        if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setWiggleSpeed(duration: 0.8, preservingPhase: false)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, image) in images.enumerated() {
            let offset = CGFloat(index) * 5
            let rect = NSRect(x: 5 + offset, y: 5 + offset, width: 86, height: 66)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            let imageRect = rect.insetBy(dx: 1.2, dy: 1.2)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: 7.8, yRadius: 7.8).addClip()
            let scale = min(imageRect.width / max(1, image.size.width), imageRect.height / max(1, image.size.height))
            let drawRect = NSRect(x: imageRect.midX - image.size.width * scale / 2, y: imageRect.midY - image.size.height * scale / 2, width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let label = page == 0 ? "\(count)" : "\(page + 1)/\(count)"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
        NSColor.systemBlue.setFill()
        let badgeWidth = max(22, (label as NSString).size(withAttributes: attributes).width + 8)
        let badge = NSRect(x: 103 - badgeWidth, y: 65, width: badgeWidth, height: 22)
        NSBezierPath(ovalIn: badge).fill()
        let labelSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: NSPoint(x: badge.midX - labelSize.width / 2,
                                            y: badge.midY - labelSize.height / 2),
                                 withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        draggingImage = false
        hold?.invalidate()
        holdRing?.removeFromSuperlayer()
        let point = convert(event.locationInWindow, from: nil)
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: point.x + 5, y: point.y + 5, width: 14, height: 14), transform: nil)
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.fillColor = nil
        ring.lineWidth = 2
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = 0.5
        layer?.addSublayer(ring)
        ring.add(fill, forKey: "holdProgress")
        holdRing = ring
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, !self.moved else { return }
            self.holdRing?.removeFromSuperlayer()
            self.beginScreenshotDrag(with: event)
        }
        RunLoop.main.add(timer, forMode: .common)
        hold = timer
        startFrame = window.frame
        startMouse = window.convertPoint(toScreen: event.locationInWindow)
        startTime = event.timestamp
        dragOffset = NSPoint(x: startMouse.x - startFrame.minX, y: startMouse.y - startFrame.minY)
        moved = false
    }

    private func beginScreenshotDrag(with event: NSEvent) {
        guard window?.isVisible == true, NSEvent.pressedMouseButtons & 1 != 0,
              let shot = PinManager.shared.latestShot, let image = shot.stackImage else { return }
        draggingImage = true
        let scale = min(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let point = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                           width: size.width, height: size.height)
        let item = NSDraggingItem(pasteboardWriter: shot.url as NSURL)
        item.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingImage, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        guard moved || hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) >= 4 else { return }
        hold?.invalidate()
        holdRing?.removeFromSuperlayer()
        if !moved { setWiggleSpeed(duration: 0.24) }
        moved = true
        window.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        setWiggleSpeed(duration: 0.8)
        hold?.invalidate()
        holdRing?.removeFromSuperlayer()
        NSCursor.arrow.set()
        guard !draggingImage else { return }
        guard moved else {
            // A press that was held must never be interpreted as a click,
            // even if the long-press timer has not fired yet.
            if event.timestamp - startTime < 0.3,
               bounds.contains(convert(event.locationInWindow, from: nil)) {
                PinManager.shared.restore()
            }
            return
        }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? window.screen else { return }
        let area = screen.visibleFrame
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let distance = hypot(dx, dy)
        let left: Bool
        let bottom: Bool
        if screen.frame.contains(startMouse), distance >= 20, event.timestamp - startTime < 0.7 {
            let dominant = max(abs(dx), abs(dy))
            left = abs(dx) >= dominant * 0.55 ? dx < 0 : startFrame.midX < area.midX
            bottom = abs(dy) >= dominant * 0.55 ? dy < 0 : startFrame.midY < area.midY
        } else {
            left = mouse.x < area.midX
            bottom = mouse.y < area.midY
        }
        let x = left ? area.minX + 18 : area.maxX - window.frame.width - 18
        let y = bottom ? area.minY + 18 : area.maxY - window.frame.height - 18
        StackCorner.remember(left: left, bottom: bottom, screen: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(NSRect(x: x, y: y, width: window.frame.width, height: window.frame.height), display: true)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        PinManager.shared.topShot?.presentMenu(event, anchor: self, stacked: true)
    }

}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Thumbnail decoding

private enum ThumbnailLoader {
    private static let queue = DispatchQueue(label: "app.shotpin.thumbnail-loader", qos: .userInitiated)
    private static let maxPixelDimension = Int(Style.maxDimension * 2)

    static func loadCapture(_ url: URL, needOriginal: Bool, completion: @escaping (NSImage?, NSImage?) -> Void) {
        queue.async {
            let result: (NSImage?, NSImage?) = autoreleasepool {
                guard needOriginal, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return (nil, nil)
                }
                let scale = min(1, CGFloat(maxPixelDimension) / CGFloat(max(original.width, original.height)))
                let width = max(1, Int(CGFloat(original.width) * scale))
                let height = max(1, Int(CGFloat(original.height) * scale))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, nil) }
                context.interpolationQuality = .high
                context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let thumbnail = context.makeImage() else { return (nil, nil) }
                return (displayImage(from: thumbnail), NSImage(cgImage: original, size: NSSize(width: original.width, height: original.height)))
            }
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    static func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            let image: NSImage? = autoreleasepool {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        return displayImage(from: cgImage)
                    }
                }
                return pdfThumbnail(url)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func pdfThumbnail(_ url: URL) -> NSImage? {
        guard url.pathExtension.lowercased() == "pdf",
              let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else { return nil }
        let bounds = page.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(CGFloat(maxPixelDimension) / bounds.width,
                        CGFloat(maxPixelDimension) / bounds.height,
                        1)
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.mediaBox,
                                                     rect: target,
                                                     rotate: 0,
                                                     preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let cgImage = context.makeImage() else { return nil }
        return displayImage(from: cgImage)
    }

    private static func displayImage(from cgImage: CGImage) -> NSImage {
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        let scale = min(Style.maxDimension / pixelSize.width,
                        Style.maxDimension / pixelSize.height,
                        1)
        let displaySize = NSSize(width: pixelSize.width * scale,
                                 height: pixelSize.height * scale)
        return NSImage(cgImage: cgImage, size: displaySize)
    }
}

// MARK: - Directory watching

private func watcherCallback(stream: ConstFSEventStreamRef,
                             info: UnsafeMutableRawPointer?,
                             numEvents: Int,
                             eventPaths: UnsafeMutableRawPointer,
                             flags: UnsafePointer<FSEventStreamEventFlags>,
                             ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    let events = (0..<min(numEvents, paths.count)).map {
        DirectoryWatcher.Event(path: paths[$0], flags: flags[$0])
    }
    watcher.receive(events)
}

final class DirectoryWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        var isFile: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 }
        var isCreatedOrMoved: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        }
        var requiresRescan: Bool {
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged) != 0
        }
    }

    enum WatchError: LocalizedError {
        case creationFailed(String)
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let path): return "Could not create an FSEvents stream for \(path)"
            case .startFailed(let path): return "Could not start the FSEvents stream for \(path)"
            }
        }
    }

    let handler: ([Event]) -> Void
    private var stream: FSEventStreamRef?

    init(path: String, handler: @escaping ([Event]) -> Void) throws {
        self.handler = handler
        var context = FSEventStreamContext(version: 0,
                                          info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil,
                                          release: nil,
                                          copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                                               watcherCallback,
                                               &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.05,
                                               flags) else { throw WatchError.creationFailed(path) }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw WatchError.startFailed(path)
        }
    }

    fileprivate func receive(_ events: [Event]) { handler(events) }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

// MARK: - App

private func makeMenuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let corners = NSBezierPath()
        corners.lineWidth = 1.7
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        corners.move(to: NSPoint(x: 3.1, y: 13.5))
        corners.line(to: NSPoint(x: 3.1, y: 15.5))
        corners.curve(to: NSPoint(x: 4.5, y: 16.9), controlPoint1: NSPoint(x: 3.1, y: 16.3), controlPoint2: NSPoint(x: 3.7, y: 16.9))
        corners.line(to: NSPoint(x: 6.5, y: 16.9))
        corners.move(to: NSPoint(x: 13.5, y: 16.9))
        corners.line(to: NSPoint(x: 15.5, y: 16.9))
        corners.curve(to: NSPoint(x: 16.9, y: 15.5), controlPoint1: NSPoint(x: 16.3, y: 16.9), controlPoint2: NSPoint(x: 16.9, y: 16.3))
        corners.line(to: NSPoint(x: 16.9, y: 13.5))
        corners.move(to: NSPoint(x: 16.9, y: 6.5))
        corners.line(to: NSPoint(x: 16.9, y: 4.5))
        corners.curve(to: NSPoint(x: 15.5, y: 3.1), controlPoint1: NSPoint(x: 16.9, y: 3.7), controlPoint2: NSPoint(x: 16.3, y: 3.1))
        corners.line(to: NSPoint(x: 13.5, y: 3.1))
        corners.move(to: NSPoint(x: 6.5, y: 3.1))
        corners.line(to: NSPoint(x: 4.5, y: 3.1))
        corners.curve(to: NSPoint(x: 3.1, y: 4.5), controlPoint1: NSPoint(x: 3.7, y: 3.1), controlPoint2: NSPoint(x: 3.1, y: 3.7))
        corners.line(to: NSPoint(x: 3.1, y: 6.5))
        corners.stroke()
        let star = NSBezierPath()
        star.move(to: NSPoint(x: 10, y: 15))
        star.curve(to: NSPoint(x: 15, y: 10), controlPoint1: NSPoint(x: 10.8, y: 12), controlPoint2: NSPoint(x: 12, y: 10.8))
        star.curve(to: NSPoint(x: 10, y: 5), controlPoint1: NSPoint(x: 12, y: 9.2), controlPoint2: NSPoint(x: 10.8, y: 8))
        star.curve(to: NSPoint(x: 5, y: 10), controlPoint1: NSPoint(x: 9.2, y: 8), controlPoint2: NSPoint(x: 8, y: 9.2))
        star.curve(to: NSPoint(x: 10, y: 15), controlPoint1: NSPoint(x: 8, y: 10.8), controlPoint2: NSPoint(x: 9.2, y: 12))
        star.close()
        star.fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "BetterShot"
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let fullscreenAutoHideKey = "fullscreenAutoHide"
    static var fullscreenAutoHideEnabled: Bool { UserDefaults.standard.bool(forKey: fullscreenAutoHideKey) }
    private lazy var fullscreenMonitor = FullscreenMonitor { [weak self] hidden in
        PinManager.shared.setFullscreenHidden(hidden, iconFrame: self?.statusIconFrame())
    }
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var lastStatusIconFrame: NSRect?
    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeMenuBarIcon()
        item.button?.toolTip = "BetterShot：左键菜单，右键截图"
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .aqua)
        menu.delegate = self
        statusMenu = menu
        statusItem = item
        DispatchQueue.main.async { [weak self] in _ = self?.statusIconFrame() }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            startSystemScreenshot()
            return
        }
        _ = statusIconFrame()
        if let menu = statusMenu { statusItem?.popUpMenu(menu) }
    }

    private func startSystemScreenshot() {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 21, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 21, keyDown: false) else { return }
        down.flags = [.maskCommand, .maskShift]
        up.flags = [.maskCommand, .maskShift]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let pins = PinManager.shared
        menu.removeAllItems()
        menu.addItem(withTitle: "当前有 " + String(pins.count) + " 张截图", action: nil, keyEquivalent: "")
        let stack = menu.addItem(withTitle: pins.collapsed ? "展开全部截图" : "收起全部截图",
                                 action: pins.count > 0 ? #selector(statusStack) : nil, keyEquivalent: "")
        stack.target = self
        let hidden = menu.addItem(withTitle: pins.manuallyHidden ? "显示全部截图" : "隐藏全部截图", action: pins.hidingAnimation ? nil : #selector(statusHidden), keyEquivalent: "")
        hidden.keyEquivalentModifierMask = []
        hidden.target = self
        menu.addItem(.separator())
        let placement = NSMenuItem(title: "截图排列位置", action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        for choice in PinPlacement.allCases {
            let item = placementMenu.addItem(withTitle: choice.title, action: #selector(statusPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == PinPlacement.current ? .on : .off
        }
        placement.submenu = placementMenu
        menu.addItem(placement)
        for (title, enabled, action) in [("自动拷贝", UserDefaults.standard.bool(forKey: "autoCopyNewShot"), #selector(statusCopy)),
                                         ("全屏自动隐藏", Self.fullscreenAutoHideEnabled, #selector(toggleFullscreenAutoHide)),
                                         ("悬停自动展开", PinManager.autoExpandEnabled, #selector(statusHover)),
                                         ("双击 Command 展开或收起", UserDefaults.standard.bool(forKey: "commandExpandStack"), #selector(toggleCommandExpand))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: enabled ? "✓" : "")
            item.keyEquivalentModifierMask = []
            item.target = self
        }
        menu.addItem(withTitle: "选择存储文件夹…", action: #selector(statusChooseFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开存储文件夹", action: #selector(statusOpenFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "恢复刚关闭的图窗", action: pins.canReopen ? #selector(statusReopen) : nil, keyEquivalent: "").target = self
        let help = NSMenuItem(title: "操作手势", action: nil, keyEquivalent: "")
        let guide = NSMenu()
        let groups: [[String]] = [
            ["菜单栏：左键菜单 · 右键截图", "系统截图：⌘⇧3 全屏 · ⌘⇧4 选区 · ⌘⇧5 更多"],
            ["截图：单击收起 · 双击标注", "截图：长按预览 · 拖动分享", "截图：向屏幕边缘快速甩动保存", "截图：右键更多操作 · 按 Option 隔空投送"],
            ["堆栈：单击展开 · 拖动或甩动换角", "堆栈：长按后拖出最新截图 · 右键设置", "悬停展开：开启后，鼠标停留即可展开", "双击 Command：开启后，展开或收起"],
            ["标注：⌘Z 撤销 · ⇧⌘Z 重做", "标注：双击已有文字重新编辑", "标注：长按已有图形或文字拖动"]
        ]
        for (index, lines) in groups.enumerated() {
            if index > 0 { guide.addItem(.separator()) }
            for line in lines { guide.addItem(withTitle: line, action: nil, keyEquivalent: "") }
        }
        help.submenu = guide
        menu.addItem(help)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 BetterShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
    }
    func menuWillOpen(_ menu: NSMenu) {
        PinManager.shared.menuTracking = true
    }
    func menuDidClose(_ menu: NSMenu) {
        PinManager.shared.menuTracking = false
    }
    @objc private func statusPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let placement = PinPlacement(rawValue: raw) else { return }
        PinPlacement.current = placement
        PinManager.shared.animatePlacement()
    }
    @objc private func statusChooseFolder() { _ = SaveDestination.chooseFolder(startingAt: SaveDestination.folder) }
    @objc private func statusOpenFolder() {
        if SaveDestination.folder == nil { _ = SaveDestination.chooseFolder(startingAt: nil) }
        SaveDestination.revealFolder()
    }
    @objc private func statusReopen() { PinManager.shared.reopen() }
    @objc private func statusStack() { PinManager.shared.toggleStack() }
    @objc private func statusHidden() {
        PinManager.shared.toggleHidden(iconFrame: lastStatusIconFrame ?? statusIconFrame())
    }
    private func statusIconFrame() -> NSRect? {
        let screens = NSScreen.screens
        if let button = statusItem?.button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if !frame.isEmpty, screens.contains(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) {
                lastStatusIconFrame = frame
            }
        }
        if let frame = lastStatusIconFrame,
           screens.contains(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) {
            return frame
        }
        return nil
    }
    @objc private func statusHover() { PinManager.shared.toggleAutoExpand() }
    @objc fileprivate func toggleFullscreenAutoHide() {
        let enabled = !Self.fullscreenAutoHideEnabled
        UserDefaults.standard.set(enabled, forKey: Self.fullscreenAutoHideKey)
        fullscreenMonitor.setEnabled(enabled)
    }

    @objc private func statusCopy() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "autoCopyNewShot"), forKey: "autoCopyNewShot")
    }

    private var globalKeys: Any?
    private var localKeys: Any?
    private var globalClicks: Any?
    private var localClicks: Any?
    private var lastCommandTap: TimeInterval = 0
    private var commandDown: TimeInterval?
    private var commandUsedWithKey = false

    @objc func toggleCommandExpand() {
        let enabled = !UserDefaults.standard.bool(forKey: "commandExpandStack")
        UserDefaults.standard.set(enabled, forKey: "commandExpandStack")
        lastCommandTap = 0
        if enabled && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
    private func handleKey(_ event: NSEvent) {
        if event.type == .keyDown {
            if commandDown != nil { commandUsedWithKey = true }
            return
        }
        if event.keyCode == 58 || event.keyCode == 61 {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option {
                PinManager.shared.airDropAtPointer()
            }
            return
        }
        guard UserDefaults.standard.bool(forKey: "commandExpandStack") else { return }
        guard event.keyCode == 55 || event.keyCode == 54 else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if commandDown == nil { commandDown = event.timestamp; commandUsedWithKey = flags != .command }
        } else if let start = commandDown {
            commandDown = nil
            guard !commandUsedWithKey, flags.isEmpty, event.timestamp - start < 0.4 else { lastCommandTap = 0; return }
            if event.timestamp - lastCommandTap < 0.4 {
                lastCommandTap = 0
                PinManager.shared.restoreWithCommand()
            } else {
                lastCommandTap = event.timestamp
            }
        }
    }
    private func installKeyMonitors() {
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            DispatchQueue.main.async { self?.handleKey(event) }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleKey(event)
            return event
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClicks = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            DispatchQueue.main.async { PinManager.shared.handleOutsideClick() }
        }
        localClicks = NSEvent.addLocalMonitorForEvents(matching: clicks) { event in
            PinManager.shared.handleOutsideClick()
            return event
        }
    }

    private var watcher: DirectoryWatcher?
    private var watchedDirectory: URL?
    private var watcherRefreshTimer: Timer?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var terminationPending = false
    private var pending: [FileIdentity: UUID] = [:]
    private var handled = Set<FileIdentity>()

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        let creationDate: Date

        init?(attributes: [FileAttributeKey: Any]) {
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let creationDate = attributes[.creationDate] as? Date else { return nil }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.creationDate = creationDate
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusMenu()
        installKeyMonitors()
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        do {
            try CaptureWorkspace.shared.begin()
        } catch {
            NSLog("ShotPin: could not create private capture workspace: %@", error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        installTerminationSignalHandlers()
        guard configureWatcher(force: true) else {
            NSApp.terminate(nil)
            return
        }
        restorePendingPins()
        fullscreenMonitor.setEnabled(Self.fullscreenAutoHideEnabled)
        CaptureWorkspace.shared.cleanupStaleWorkspaces()
        watcherRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            CaptureWorkspace.shared.cleanupStaleWorkspaces()
            self?.configureWatcher(force: false)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { _ in
            DispatchQueue.main.async { PinManager.shared.layout() }
        }
    }

    private func restorePendingPins() {
        let paths = PendingPins.paths
        let display = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? 0
        func restoreNext(_ index: Int) {
            guard index < paths.count else { return }
            let url = URL(fileURLWithPath: paths[index])
            guard shotFileManager.fileExists(atPath: url.path) else {
                // Keep the record: a temporarily unavailable volume may return.
                restoreNext(index + 1)
                return
            }
            ThumbnailLoader.load(url) { image in
                if let image, PendingPins.contains(url) {
                    PinManager.shared.add(url: url, image: image, targetDisplayID: display)
                }
                restoreNext(index + 1)
            }
        }
        restoreNext(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        watcherRefreshTimer?.invalidate()
        watcher = nil
        CaptureWorkspace.shared.end {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// launchctl normally stops agents with SIGTERM. Convert that signal into a
    /// normal AppKit termination so the capture location is always restored.
    private func installTerminationSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, !self.terminationPending else { return }
                self.perform(#selector(self.terminateFromSignal), with: nil, afterDelay: 0)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    @objc private func terminateFromSignal() {
        guard !terminationPending else { return }
        NSApp.terminate(nil)
    }

    @discardableResult
    private func configureWatcher(force: Bool) -> Bool {
        let directory = screenshotDirectory().standardizedFileURL
        guard force || directory != watchedDirectory || watcher == nil else { return true }
        watcher = nil
        watchedDirectory = directory
        do {
            watcher = try DirectoryWatcher(path: directory.path) { [weak self] events in
                self?.receive(events)
            }
            NSLog("ShotPin: watching %@", directory.path)
            // The stream starts at "now", so scan after it is live to close the
            // redirect-to-watcher startup gap without losing intervening captures.
            rescanWatchedDirectory()
            return true
        } catch {
            NSLog("ShotPin: watcher unavailable for %@: %@; retrying", directory.path, error.localizedDescription)
            return false
        }
    }

    private func receive(_ events: [DirectoryWatcher.Event]) {
        if events.contains(where: \DirectoryWatcher.Event.requiresRescan) {
            NSLog("ShotPin: FSEvents reported dropped or invalidated events; rescanning")
            rescanWatchedDirectory()
            configureWatcher(force: true)
        }
        for event in events where event.isFile && event.isCreatedOrMoved {
            consider(path: event.path)
        }
    }

    private func rescanWatchedDirectory() {
        guard let directory = watchedDirectory,
              let contents = try? shotFileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return }
        for url in contents { consider(path: url.path) }
    }

    private func consider(path: String) {
        guard let directory = watchedDirectory else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // ShotPin's own in-place writes replace the inode, which looks like a
        // brand-new capture to the watcher. Skip them instead of pinning twice.
        guard !EventSuppressor.shared.isSuppressed(url) else { return }
        // FSEvents watches directory trees. Screenshots only land directly in the
        // configured destination, so accepting descendants catches unrelated files.
        guard url.deletingLastPathComponent() == directory else { return }
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), watchedExtensions.contains(url.pathExtension.lowercased()) else { return }
        guard let attributes = try? shotFileManager.attributesOfItem(atPath: path),
              let identity = FileIdentity(attributes: attributes) else { return }
        let isPrivateDirectory = CaptureWorkspace.shared.directory?.standardizedFileURL == directory
        if !isPrivateDirectory {
            let age = Date().timeIntervalSince(identity.creationDate)
            guard age >= 0, age < 15 else { return }
        }
        guard pending[identity] == nil, !handled.contains(identity) else { return }
        let token = UUID()
        let pointer = NSEvent.mouseLocation
        let targetDisplayID = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.displayID
            ?? NSScreen.main?.displayID
            ?? NSScreen.screens.first?.displayID
            ?? 0
        pending[identity] = token
        pin(url: url,
            identity: identity,
            token: token,
            targetDisplayID: targetDisplayID,
            attempt: 0,
            lastSize: -1,
            stableSamples: 0)
    }

    /// Spotlight metadata and the file bytes both land slightly after the create
    /// event, so retry briefly before giving up or pinning on the fallback path.
    private func pin(url: URL,
                     identity: FileIdentity,
                     token: UUID,
                     targetDisplayID: CGDirectDisplayID,
                     attempt: Int,
                     lastSize: Int,
                     stableSamples: Int) {
        guard pending[identity] == token else { return }
        let maxAttempts = 80
        let attributes = try? shotFileManager.attributesOfItem(atPath: url.path)
        guard let attributes, FileIdentity(attributes: attributes) == identity else {
            pending.removeValue(forKey: identity)
            return
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let nextStableSamples = size > 0 && size == lastSize ? stableSamples + 1 : 0
        let stable = nextStableSamples >= 2
        let capture = isScreenCapture(url)
        let isPrivateCapture = CaptureWorkspace.shared.directory?.standardizedFileURL
            == url.deletingLastPathComponent().standardizedFileURL

        if !isPrivateCapture && capture == false {
            pending.removeValue(forKey: identity)
            handled.insert(identity)
            return
        }
        let exhausted = attempt >= maxAttempts
        // When Spotlight is unavailable, only macOS' generated filename is accepted.
        // Arbitrarily named screencapture CLI output normally carries Spotlight's
        // capture attribute and follows the authoritative branch above.
        let generatedNameFallback = capture == nil && hasGeneratedScreenshotName(url)
        if (stable && isPrivateCapture)
            || (stable && capture == true)
            || (exhausted && stable && generatedNameFallback) {
            show(url: url,
                 identity: identity,
                 token: token,
                 targetDisplayID: targetDisplayID,
                 attempt: attempt,
                 size: size)
            return
        }
        guard !exhausted else {
            pending.removeValue(forKey: identity)
            handled.insert(identity)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.pin(url: url,
                      identity: identity,
                      token: token,
                      targetDisplayID: targetDisplayID,
                      attempt: attempt + 1,
                      lastSize: size,
                      stableSamples: nextStableSamples)
        }
    }

    private func show(url: URL,
                      identity: FileIdentity,
                      token: UUID,
                      targetDisplayID: CGDirectDisplayID,
                      attempt: Int,
                      size: Int,
                      metadataRetries: Int = 0) {
        guard pending[identity] == token,
              shotFileManager.fileExists(atPath: url.path) else {
            pending.removeValue(forKey: identity)
            return
        }
        let sourceRect = captureScreenRect(url)
        // The image can be complete before macOS attaches its capture rectangle,
        // especially when several screenshots are saved in quick succession.
        if sourceRect == nil, metadataRetries < 3,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.show(url: url, identity: identity, token: token,
                           targetDisplayID: targetDisplayID, attempt: attempt,
                           size: size, metadataRetries: metadataRetries + 1)
            }
            return
        }
        let needOriginal = sourceRect != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let finish: (NSImage?, NSImage?) -> Void = { [weak self] image, original in
            guard let self, self.pending[identity] == token else { return }
            guard let attributes = try? shotFileManager.attributesOfItem(atPath: url.path),
                  FileIdentity(attributes: attributes) == identity else {
                self.pending.removeValue(forKey: identity)
                return
            }
            let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard currentSize == size else {
                self.pin(url: url, identity: identity, token: token, targetDisplayID: targetDisplayID,
                         attempt: attempt + 1, lastSize: currentSize, stableSamples: 0)
                return
            }
            if let image, image.size.width > 0, image.size.height > 0 {
                self.pending.removeValue(forKey: identity)
                self.handled.insert(identity)
                guard let workspace = CaptureWorkspace.shared.directory else { return }
                let capture: URL
                do {
                    capture = try moveCaptureToWorkspace(url, workspace: workspace)
                } catch {
                    NSLog("ShotPin: could not move screenshot for pin: %@", error.localizedDescription)
                    return
                }
                if UserDefaults.standard.bool(forKey: "autoCopyNewShot") {
                    ShotView.copyImage(capture)
                }
                PinManager.shared.add(url: capture, image: image, targetDisplayID: targetDisplayID,
                                      arrivalImage: original, sourceRect: sourceRect)
                return
            }

            let maxAttempts = 80
            guard attempt < maxAttempts else {
                self.pending.removeValue(forKey: identity)
                self.handled.insert(identity)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.pin(url: url,
                          identity: identity,
                          token: token,
                          targetDisplayID: targetDisplayID,
                          attempt: attempt + 1,
                          lastSize: size,
                          stableSamples: 2)
            }
        }
        if needOriginal {
            ThumbnailLoader.loadCapture(url, needOriginal: true) { image, original in
                if let image { finish(image, original) }
                else { ThumbnailLoader.load(url) { finish($0, nil) } }
            }
        } else {
            ThumbnailLoader.load(url) { finish($0, nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
