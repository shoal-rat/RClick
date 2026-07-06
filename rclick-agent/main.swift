//
//  main.swift
//  RClick Agent
//
//  Headless replacement for the RClick main app. Speaks RClick v2.0.4's
//  DistributedNotificationCenter IPC protocol (Messager/MessageSecurity,
//  compiled from RClick's own sources) so the original signed FinderSync
//  extension gets its menu config and click handling without RClick.app
//  ever running — which is what fired the macOS "access data from other
//  apps" prompt (RClick probes ~/Library/Mail, Messages, Safari at launch).
//
//  Action implementations ported from Codex's "RClick Finder Actions"
//  Services helper (finder-actions/main.swift).
//

import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.zwk.rclick-agent", category: "agent")

private let rclickBundleID = "cn.wflixu.RClick"

// MARK: - Menu item ids (namespaced so a stray RClick.app instance ignores them)

private enum MenuID {
    // actions group ("Actions" submenu)
    static let copyRelPath = "zk-copy-relpath"
    static let copyName = "zk-copy-name"
    static let copyNameNoExt = "zk-copy-name-noext"
    static let moveTo = "zk-move-to"
    static let copyTo = "zk-copy-to"
    static let sha256 = "zk-sha256"
    static let toggleHidden = "zk-toggle-hidden"
    // apps group (rendered inline at top level)
    static let openTerminal = "zk-open-terminal"
    static let openVSCode = "zk-open-vscode"
    static let copyPath = "zk-copy-path"
    static let compress = "zk-compress"
    static let airdrop = "zk-airdrop"
    static let deleteDirect = "zk-delete"
    // newFiles group ("New File" submenu)
    static let newTxt = "zk-new-txt"
    static let newMd = "zk-new-md"
    static let newPy = "zk-new-py"
    static let newJson = "zk-new-json"
    static let newHtml = "zk-new-html"
    static let newDocx = "zk-new-docx"
    static let newPptx = "zk-new-pptx"
    static let newXlsx = "zk-new-xlsx"
    // commonDirs group ("Common Folders" submenu)
    static let dirDesktop = "zk-dir-desktop"
    static let dirDocuments = "zk-dir-documents"
    static let dirDownloads = "zk-dir-downloads"
    static let dirHome = "zk-dir-home"
    static let dirApplications = "zk-dir-applications"
    static let dirCodex = "zk-dir-codex"
}

// MARK: - Agent core

final class AgentCore: NSObject {
    private let messager = Messager.shared
    private let fm = FileManager.default
    private var menuVersion = 0
    private let workQueue = DispatchQueue(label: "dev.zwk.rclick-agent.work", qos: .userInitiated)

    /// Encoded snapshot of the last menu we broadcast. Used to suppress
    /// redundant resends: the extension flushes its icon cache on every
    /// menu-config it receives, so replying to each 10 s heartbeat with an
    /// identical config would needlessly churn it forever. We resend only when
    /// the content actually changes (which, in practice, is only when the
    /// hidden-files label flips).
    private var lastSentSignature: String?

    /// Forced sends are fire-and-forget over DistributedNotificationCenter and
    /// can be silently dropped (extension mid-launch/suspended, distnoted
    /// coalescing). The extension never re-requests once its cache is populated,
    /// so a dropped forced send would strand it on a stale menu. After each
    /// forced send we let the next few heartbeats resend unconditionally, so a
    /// lost send self-heals within ~30 s; then we revert to change-only sends.
    private var forceResendsRemaining = 0

    /// True while a folder picker is on screen. Main-thread-only state: every
    /// click arrives on the main run loop (DistributedNotificationCenter
    /// observer registered on main), and a modal run loop re-enters that same
    /// loop, so a plain Bool is race-free here. Used to drop clicks that would
    /// otherwise open a second panel and act on a stale selection.
    private var uiBusy = false

    private var home: URL { fm.homeDirectoryForCurrentUser }

    // Paths delete/move must never operate on directly.
    private lazy var protectedPaths: Set<String> = {
        var paths: Set<String> = [
            "/", "/Applications", "/System", "/Library", "/Users",
            "/usr", "/bin", "/sbin", "/var", "/private", "/tmp",
        ]
        paths.insert(home.path)
        for sub in ["Desktop", "Documents", "Downloads", "Library", "Applications"] {
            paths.insert(home.appendingPathComponent(sub).path)
        }
        return paths
    }()

    // MARK: Wiring

    func start() {
        // An explicit request always gets a fresh config: the extension only
        // asks when its cache is empty (on launch, or on a menu open with no
        // cached config), so this is the reliable delivery path.
        messager.onExtensionMessage(.requestConfig) { [weak self] _ in
            self?.sendConfig(force: true)
        }
        // Heartbeats arrive every 10 s. Reply only if the menu changed since we
        // last sent it — otherwise this is a no-op, keeping the agent idle and
        // sparing the extension a pointless icon-cache flush.
        messager.onExtensionMessage(.heartbeat) { [weak self] _ in
            self?.sendConfig(force: false)
        }
        messager.onExtensionMessage(.click) { [weak self] data in
            guard let self else { return }
            if let event: ClickEventPayload = self.messager.decodeSignedData(data, as: ClickEventPayload.self) {
                self.handle(event)
            } else {
                log.warning("Dropped click event with invalid signature/payload")
            }
        }

        messager.sendRunningNotification(directories: ["/Users/"])
        sendConfig(force: true)
        log.info("RClick Agent started")
    }

    // MARK: Menu config

    /// Broadcast the menu config to the extension. When `force` is false, the
    /// send is skipped if the config is byte-identical to the last one sent.
    func sendConfig(force: Bool) {
        let showingHidden = Self.finderShowsHiddenFiles()
        // The only dynamic part of the menu is the hidden-files label, so the
        // signature is just that state; cheap and sufficient.
        let signature = showingHidden ? "hidden:on" : "hidden:off"
        if force {
            forceResendsRemaining = 3            // ~30 s of self-heal retries
        } else if forceResendsRemaining > 0 {
            forceResendsRemaining -= 1           // drain a retry: resend regardless of signature
        } else if signature == lastSentSignature {
            return                               // steady state: nothing changed, stay quiet
        }
        lastSentSignature = signature
        menuVersion += 1

        let actions: [ActionMenuItem] = [
            .init(id: MenuID.copyRelPath, name: "Copy Relative Path", icon: "arrow.turn.down.right", tag: 0),
            .init(id: MenuID.copyName, name: "Copy File Name", icon: "textformat", tag: 1),
            .init(id: MenuID.copyNameNoExt, name: "Copy Name w/o Extension", icon: "textformat.alt", tag: 2),
            .init(id: MenuID.moveTo, name: "Move To…", icon: "arrow.right.square", tag: 3),
            .init(id: MenuID.copyTo, name: "Copy To…", icon: "plus.square.on.square", tag: 4),
            .init(id: MenuID.sha256, name: "Calculate SHA-256", icon: "number.square", tag: 5),
            .init(id: MenuID.toggleHidden,
                  name: showingHidden ? "Hide Hidden Files" : "Show Hidden Files",
                  icon: showingHidden ? "eye.slash" : "eye", tag: 6),
        ]

        let apps: [AppMenuItem] = [
            .init(id: MenuID.openTerminal, name: "Open in Terminal", icon: "terminal", tag: 0,
                  appURL: "/System/Applications/Utilities/Terminal.app"),
            .init(id: MenuID.openVSCode, name: "Open in VS Code", icon: "chevron.left.forwardslash.chevron.right", tag: 1,
                  appURL: "/Applications/Visual Studio Code.app"),
            .init(id: MenuID.copyPath, name: "Copy Path", icon: "doc.on.clipboard", tag: 2),
            .init(id: MenuID.compress, name: "Compress", icon: "archivebox", tag: 3),
            .init(id: MenuID.airdrop, name: "AirDrop", icon: "dot.radiowaves.left.and.right", tag: 4),
            .init(id: MenuID.deleteDirect, name: "Move to Trash", icon: "trash", tag: 5),
        ]

        let newFiles: [NewFileMenuItem] = [
            .init(id: MenuID.newTxt, name: "Text", ext: ".txt", icon: "doc.text"),
            .init(id: MenuID.newMd, name: "Markdown", ext: ".md", icon: "doc.richtext"),
            .init(id: MenuID.newPy, name: "Python", ext: ".py", icon: "chevron.left.forwardslash.chevron.right"),
            .init(id: MenuID.newJson, name: "JSON", ext: ".json", icon: "curlybraces"),
            .init(id: MenuID.newHtml, name: "HTML", ext: ".html", icon: "globe"),
            .init(id: MenuID.newDocx, name: "Word (.docx)", ext: ".docx", icon: "doc.richtext.fill"),
            .init(id: MenuID.newPptx, name: "PowerPoint (.pptx)", ext: ".pptx", icon: "rectangle.on.rectangle.fill"),
            .init(id: MenuID.newXlsx, name: "Excel (.xlsx)", ext: ".xlsx", icon: "tablecells"),
        ]

        let commonDirs: [CommonDirMenuItem] = [
            .init(id: MenuID.dirDesktop, name: "Desktop", icon: "desktopcomputer",
                  url: home.appendingPathComponent("Desktop").path),
            .init(id: MenuID.dirDocuments, name: "Documents", icon: "doc.text",
                  url: home.appendingPathComponent("Documents").path),
            .init(id: MenuID.dirDownloads, name: "Downloads", icon: "arrow.down.circle",
                  url: home.appendingPathComponent("Downloads").path),
            .init(id: MenuID.dirHome, name: "Home", icon: "house", url: home.path),
            .init(id: MenuID.dirApplications, name: "Applications", icon: "square.grid.2x2",
                  url: "/Applications"),
            .init(id: MenuID.dirCodex, name: "Codex Projects", icon: "folder.badge.gearshape",
                  url: home.appendingPathComponent("Documents/Codex").path),
        ]

        let config = MenuConfigPayload(
            version: menuVersion,
            actions: actions,
            apps: apps,
            newFiles: newFiles,
            commonDirs: commonDirs,
            actionsCollapsed: true,
            appsCollapsed: false,
            newFilesCollapsed: true,
            commonDirsCollapsed: true
        )
        messager.sendMenuConfig(config)
    }

    private static func finderShowsHiddenFiles() -> Bool {
        guard let value = CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString,
                                                    "com.apple.finder" as CFString) else { return false }
        if let b = value as? Bool { return b }
        if let n = value as? Int { return n != 0 }
        if let s = value as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        return false
    }

    // MARK: Click dispatch

    func handle(_ event: ClickEventPayload) {
        // Runs on the main thread. If a dialog is already up, drop this click:
        // queueing it would execute against a stale selection after the user
        // has moved on, and nesting a second modal over an open panel is how a
        // Delete confirmation can end up stacked on a Move panel.
        if uiBusy {
            log.warning("Ignoring click \(event.itemId, privacy: .public): a dialog is already open")
            return
        }
        log.info("Click: \(event.itemId, privacy: .public) targets=\(event.target.count)")
        let urls = event.target.map { URL(fileURLWithPath: $0).standardizedFileURL }

        switch event.itemId {
        case MenuID.copyPath:
            copyLines(urls.map(\.path))
        case MenuID.copyRelPath:
            copyRelativePaths(urls)
        case MenuID.copyName:
            copyLines(urls.map(\.lastPathComponent))
        case MenuID.copyNameNoExt:
            copyLines(urls.map { $0.deletingPathExtension().lastPathComponent })
        case MenuID.moveTo:
            transfer(urls, move: true)
        case MenuID.copyTo:
            transfer(urls, move: false)
        case MenuID.deleteDirect:
            moveToTrash(urls)
        case MenuID.compress:
            compress(urls)
        case MenuID.sha256:
            sha256(urls)
        case MenuID.airdrop:
            airDrop(urls)
        case MenuID.toggleHidden:
            toggleHiddenFiles()
        case MenuID.openTerminal:
            openIn(bundleID: "com.apple.Terminal",
                   fallback: "/System/Applications/Utilities/Terminal.app",
                   appName: "Terminal", urls: urls, directoriesOnly: true)
        case MenuID.openVSCode:
            openIn(bundleID: "com.microsoft.VSCode",
                   fallback: "/Applications/Visual Studio Code.app",
                   appName: "Visual Studio Code", urls: urls, directoriesOnly: false)
        case MenuID.newTxt: createNewFile("Untitled.txt", contents: .plain(""), targets: urls)
        case MenuID.newMd: createNewFile("Untitled.md", contents: .plain(""), targets: urls)
        case MenuID.newPy: createNewFile("Untitled.py", contents: .plain(""), targets: urls)
        case MenuID.newJson: createNewFile("Untitled.json", contents: .plain("{}\n"), targets: urls)
        case MenuID.newHtml: createNewFile("Untitled.html", contents: .plain(Self.htmlTemplate), targets: urls)
        case MenuID.newDocx: createNewFile("Untitled.docx", contents: .template("blank.docx"), targets: urls)
        case MenuID.newPptx: createNewFile("Untitled.pptx", contents: .template("blank.pptx"), targets: urls)
        case MenuID.newXlsx: createNewFile("Untitled.xlsx", contents: .template("blank.xlsx"), targets: urls)
        case MenuID.dirDesktop, MenuID.dirDocuments, MenuID.dirDownloads,
             MenuID.dirHome, MenuID.dirApplications, MenuID.dirCodex:
            for url in urls { NSWorkspace.shared.open(url) }
        default:
            log.warning("Unknown menu id: \(event.itemId, privacy: .public)")
        }
    }

    // MARK: Clipboard actions

    private func copyLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func copyRelativePaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let base = relativeBase(for: urls)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let lines = urls.map { url -> String in
            url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
        }
        copyLines(lines)
    }

    /// Longest common ancestor of the parent directories of all selected items.
    private func relativeBase(for urls: [URL]) -> String {
        let paths = urls.map { $0.deletingLastPathComponent().standardizedFileURL.path }
        guard var common = paths.first else { return NSHomeDirectory() }
        for path in paths.dropFirst() {
            while !path.hasPrefix(common.hasSuffix("/") ? common : common + "/"), common != "/" {
                common = URL(fileURLWithPath: common).deletingLastPathComponent().path
            }
        }
        return common
    }

    // MARK: New file creation

    private enum NewFileContents {
        case plain(String)
        case template(String)
    }

    private static let htmlTemplate = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Untitled</title>
    </head>
    <body>
    </body>
    </html>

    """

    private func createNewFile(_ fileName: String, contents: NewFileContents, targets: [URL]) {
        guard let directory = targetDirectory(from: targets) else {
            report(title: "New File", message: "Could not determine the destination folder.")
            return
        }
        let target = uniqueDestination(for: directory.appendingPathComponent(fileName), suggestedName: fileName)
        do {
            switch contents {
            case .plain(let text):
                try text.write(to: target, atomically: true, encoding: .utf8)
            case .template(let templateName):
                guard let template = officeTemplate(named: templateName) else {
                    report(title: "New File Failed",
                              message: "Missing template \(templateName). Rebuild the agent or restore ~/Library/Application Support/RClick/Templates.")
                    return
                }
                try fm.copyItem(at: template, to: target)
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
            maybeStartRename()
        } catch {
            report(title: "New File Failed", message: error.localizedDescription)
        }
    }

    /// Prefer user-editable templates in App Support; fall back to the copies bundled at build time.
    private func officeTemplate(named name: String) -> URL? {
        let appSupport = home.appendingPathComponent("Library/Application Support/RClick/Templates")
            .appendingPathComponent(name)
        if fm.fileExists(atPath: appSupport.path) { return appSupport }
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil),
           fm.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }

    /// First target if it is a directory, its parent if it is a file,
    /// else the front Finder window's folder, else Desktop.
    private func targetDirectory(from targets: [URL]) -> URL? {
        if let first = targets.first {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: first.path, isDirectory: &isDir) {
                return isDir.boolValue ? first : first.deletingLastPathComponent()
            }
            return first
        }
        return frontFinderDirectory() ?? home.appendingPathComponent("Desktop")
    }

    /// If Accessibility happens to be granted, press Return so the new file
    /// enters rename mode (Windows-style). Never prompts; silently skipped.
    private func maybeStartRename() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Deliver only if Finder is frontmost at fire time, and post to
            // Finder's PID rather than the global HID tap — otherwise a focus
            // change in the 0.6 s window could type Return into another app or,
            // worse, confirm this agent's own Delete alert.
            guard let finder = NSWorkspace.shared.frontmostApplication,
                  finder.bundleIdentifier == "com.apple.finder" else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?
                .postToPid(finder.processIdentifier)
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?
                .postToPid(finder.processIdentifier)
        }
    }

    // MARK: Move To / Copy To

    private func transfer(_ urls: [URL], move: Bool) {
        guard !urls.isEmpty else { return }
        let verb = move ? "Move" : "Copy"
        if move, let blocked = urls.first(where: { protectedPaths.contains($0.standardizedFileURL.path) }) {
            report(title: "\(verb) To", message: "\"\(blocked.lastPathComponent)\" is a protected folder and was not moved.")
            return
        }
        guard let destination = chooseFolder(title: "\(verb) \(urls.count) item\(urls.count == 1 ? "" : "s") to…",
                                             startingIn: urls.first?.deletingLastPathComponent()) else { return }
        workQueue.async { [self] in
            var failures: [String] = []
            var results: [URL] = []
            for source in urls {
                let target = uniqueDestination(for: source, inside: destination)
                do {
                    if move {
                        try fm.moveItem(at: source, to: target)
                    } else {
                        try fm.copyItem(at: source, to: target)
                    }
                    results.append(target)
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                if !results.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(results)
                }
                if !failures.isEmpty {
                    self.report(title: "\(verb) To failed for \(failures.count) item(s)",
                                   message: failures.joined(separator: "\n"))
                }
            }
        }
    }

    private func chooseFolder(title: String, startingIn: URL?) -> URL? {
        onMain {
            self.uiBusy = true
            defer { self.uiBusy = false }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = title
            panel.message = title
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if let startingIn { panel.directoryURL = startingIn }
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    // MARK: Move to Trash

    /// Windows Recycle-Bin behaviour: move to Trash (recoverable) rather than a
    /// permanent delete. Because it is recoverable there is no confirmation
    /// prompt — the agent stays silent and windowless.
    private func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let deletable = urls.filter { !protectedPaths.contains($0.standardizedFileURL.path) }
        guard !deletable.isEmpty else {
            report(title: "Move to Trash", message: "Only protected folders were selected; nothing was trashed.")
            return
        }
        // Off the main thread: trashing a large batch on a slow volume would
        // otherwise stall the run loop (and every queued click).
        workQueue.async { [self] in
            for url in deletable {
                do {
                    var resulting: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                } catch {
                    report(title: "Move to Trash", message: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Compress

    private func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        workQueue.async { [self] in
            do {
                if urls.count == 1 {
                    let source = urls[0]
                    let suggested = source.deletingPathExtension().lastPathComponent + ".zip"
                    let target = uniqueDestination(
                        for: source.deletingLastPathComponent().appendingPathComponent(suggested),
                        suggestedName: suggested)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: source.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        // --keepParent makes the folder itself the archive root
                        // (Finder-style); for a single file it would wrap the
                        // file in its parent directory's name instead.
                        try runProcess("/usr/bin/ditto",
                                       ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, target.path])
                    } else {
                        try runProcess("/usr/bin/zip", ["-qry", target.path, source.lastPathComponent],
                                       currentDirectory: source.deletingLastPathComponent())
                    }
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                    return
                }
                let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
                guard parents.count == 1, let parentPath = parents.first else {
                    report(title: "Compress", message: "Select items in the same folder to compress them together.")
                    return
                }
                let parent = URL(fileURLWithPath: parentPath)
                let target = uniqueDestination(for: parent.appendingPathComponent("Archive.zip"),
                                               suggestedName: "Archive.zip")
                var arguments = ["-qry", target.path]
                arguments.append(contentsOf: urls.map(\.lastPathComponent))
                try runProcess("/usr/bin/zip", arguments, currentDirectory: parent)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([target]) }
            } catch {
                report(title: "Compress Failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: SHA-256

    private func sha256(_ urls: [URL]) {
        let files = urls.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        guard !files.isEmpty else {
            report(title: "Calculate SHA-256", message: "Select at least one file (folders are skipped).")
            return
        }
        let skipped = urls.count - files.count
        workQueue.async { [self] in
            var lines: [String] = []
            do {
                for file in files {
                    var hasher = SHA256()
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    while true {
                        let chunk = try autoreleasepool {
                            try handle.read(upToCount: 1024 * 1024)
                        }
                        guard let chunk, !chunk.isEmpty else { break }
                        hasher.update(data: chunk)
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    lines.append("\(digest)  \(file.path)")
                }
            } catch {
                report(title: "SHA-256 Failed", message: error.localizedDescription)
                return
            }
            DispatchQueue.main.async {
                // Silent success: copy the hashes to the clipboard, no blocking
                // modal (a "Windows-like" quiet copy, matching the reference
                // helper). Only surface an alert when some folders were skipped.
                self.copyLines(lines)
                if skipped > 0 {
                    self.report(title: "SHA-256",
                                   message: "\(lines.count) hash\(lines.count == 1 ? "" : "es") copied to clipboard. \(skipped) folder(s) skipped.")
                }
            }
        }
    }

    // MARK: AirDrop

    private func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop),
                  service.canPerform(withItems: urls) else {
                self.report(title: "AirDrop", message: "AirDrop is not available for this selection.")
                return
            }
            service.perform(withItems: urls)
        }
    }

    // MARK: Hidden files toggle

    private func toggleHiddenFiles() {
        let newValue = Self.finderShowsHiddenFiles() ? "NO" : "YES"
        // Off the main thread: runProcess blocks on waitUntilExit, and killall
        // Finder can take a moment.
        workQueue.async { [self] in
            do {
                try runProcess("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", newValue])
                _ = try? runProcess("/usr/bin/killall", ["Finder"])
                // Back on main so sendConfig reads the just-written pref and the
                // label flips immediately.
                DispatchQueue.main.async { self.sendConfig(force: true) }
            } catch {
                report(title: "Show Hidden Files", message: error.localizedDescription)
            }
        }
    }

    // MARK: Open in Terminal / VS Code

    private func openIn(bundleID: String, fallback: String, appName: String, urls: [URL], directoriesOnly: Bool) {
        var targets = urls
        if targets.isEmpty {
            targets = [frontFinderDirectory() ?? home.appendingPathComponent("Desktop")]
        }
        if directoriesOnly {
            targets = targets.map { url in
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
                return url.deletingLastPathComponent()
            }
            targets = NSOrderedSet(array: targets).array as! [URL]
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? (fm.fileExists(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil) else {
            report(title: appName, message: "\(appName) is not installed.")
            return
        }
        NSWorkspace.shared.open(targets, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                self.report(title: "Open in \(appName) failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: Shared helpers

    private func frontFinderDirectory() -> URL? {
        // `with timeout` bounds the Apple-event wait: if Finder is mid-relaunch
        // (e.g. right after the hidden-files killall) this returns in ~5 s
        // instead of hanging the main thread up to the default ~2-minute AE
        // timeout.
        let source = """
        with timeout of 5 seconds
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (path to desktop folder as alias)
            end if
        end tell
        end timeout
        """
        var scriptError: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&scriptError).stringValue,
              !output.isEmpty else { return nil }
        return URL(fileURLWithPath: output).standardizedFileURL
    }

    private func uniqueDestination(for source: URL, inside destination: URL) -> URL {
        var candidate = destination.appendingPathComponent(source.lastPathComponent)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = destination.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return destination.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
    }

    private func uniqueDestination(for firstCandidate: URL, suggestedName: String) -> URL {
        var candidate = firstCandidate
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let source = URL(fileURLWithPath: suggestedName)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let directory = firstCandidate.deletingLastPathComponent()
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString + "-" + suggestedName)
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String], currentDirectory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Close the read end on every exit path. Without this each call leaks
        // one fd; under launchd's soft limit of 256 fds a 24/7 agent would
        // exhaust its table after a few hundred Compress / hidden-files clicks
        // and then silently fail every subsequent operation.
        defer { try? pipe.fileHandleForReading.close() }
        try process.run()
        // Drain before waiting: a pipe holds only ~64KB, and a child that
        // fills it blocks on write() while we block in waitUntilExit() — a
        // classic deadlock (e.g. ditto printing "Operation not permitted" for
        // every file in a large unreadable tree). readDataToEndOfFile keeps the
        // pipe drained and returns at EOF when the child exits.
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "dev.zwk.rclick-agent", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed: \(output)"])
        }
        return output
    }

    /// Report a failure. The agent is an invisible background helper, so this
    /// never shows a window or alert — failures go to the unified log only.
    /// Inspect with:
    ///   log show --last 10m --predicate 'subsystem == "dev.zwk.rclick-agent"'
    private func report(title: String, message: String) {
        log.error("\(title, privacy: .public): \(message, privacy: .public)")
    }

    private func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = AgentCore()
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandling()
        terminateRogueRClick()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        core.start()
    }

    // launchd sends SIGTERM on `launchctl bootout` (and at logout/update).
    // Handle it cleanly: tell the extension we're gone, then exit 0 so
    // KeepAlive{SuccessfulExit=false} does not respawn us.
    private func installSignalHandling() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Messager.shared.sendQuitNotification()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        Messager.shared.sendQuitNotification()
    }

    // RClick.app must never run: its launch-time permission probe fires the
    // "access data from other apps" prompt, and a second config source would
    // fight this agent. Quit it immediately if it appears.
    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == rclickBundleID else { return }
        log.warning("RClick.app launched; terminating it (agent replaces it)")
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !app.isTerminated { app.forceTerminate() }
        }
    }

    private func terminateRogueRClick() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: rclickBundleID) {
            log.warning("RClick.app running at agent start; terminating it")
            app.terminate()
        }
    }
}

// MARK: - Entry point

@main
struct RClickAgentMain {
    static func main() {
        // Single instance: hold an exclusive lock on a file for our whole
        // lifetime. A second copy (e.g. the user double-clicks the app while
        // the LaunchAgent copy is already running) fails the lock and exits,
        // so clicks are never handled twice.
        guard acquireSingleInstanceLock() else {
            FileHandle.standardError.write(Data("RClick Agent already running; exiting.\n".utf8))
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory = no Dock icon, no menu bar, never becomes active on its
        // own — an invisible background helper.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Returns true iff we obtained the lock. The file descriptor is
    /// intentionally leaked so the flock is held until the process exits.
    private static func acquireSingleInstanceLock() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RClick Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("agent.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true } // can't lock → don't block startup
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
