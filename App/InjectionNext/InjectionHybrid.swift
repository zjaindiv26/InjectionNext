//
//  InjectionHybrid.swift
//  InjectionNext
//
//  Created by John Holdsworth on 09/11/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  Provide file watcher/log parser fallback
//  for use outside Xcode (e.g. Cursor/VSCode)
//  Also uses FileWatcher for operation when
//  swift-frontend has been replaced by a
//  script to capture compiler invocations.
//
import Cocoa

extension AppDelegate {
    static var watchers = [String: InjectionHybrid]()
    static var lastWatched: String?

    @IBAction func watchProject(_ sender: NSMenuItem) {
        let open = NSOpenPanel()
        open.prompt = "Select Project Directory"
        open.canChooseDirectories = true
        open.canChooseFiles = false
        // open.showsHiddenFiles = TRUE;
        if open.runModal() == .OK, let url = open.url {
            Reloader.xcodeDev = Defaults.xcodePath+"/Contents/Developer"
            watch(path: url.path)
        } else {
            Self.watchers.removeAll()
            Self.lastWatched = nil
        }
    }

    func watch(path: String) {
        guard Self.alreadyWatching(path) == nil else { return }
        GitIgnoreParser.monitor(directory: path)
        Reloader.injectionQueue = .main
        setenv(INJECTION_DIRECTORIES,
               NSHomeDirectory()+"/Library/Developer,"+path, 1)
        Self.watchers[path] = InjectionHybrid()
        Self.lastWatched = path
        watchDirectoryItem.state = Self.watchers.isEmpty ? .off : .on
    }
    static func alreadyWatching(_ projectRoot: String) -> String? {
        return watchers.keys.first { projectRoot.hasPrefix($0) }
    }
    static func restartLastWatcher() {
        DispatchQueue.main.async {
            lastWatched.flatMap { watchers[$0]?.watcher?.restart() }
        }
    }
}

class InjectionHybrid: InjectionBase {
    static var pendingFilesChanged = [String]()
    /// Repository locked state - stops processing until app reconnects
    static var isRepositoryLocked = false
    /// Path to detected git lock file - used to check if git operation still active
    static var gitLockPath: String?
    /// Timestamp of when lock was detected
    static var lockDetectedTime: TimeInterval?
    /// InjectionNext compiler that uses InjectionLite log parser
    var liteRecompiler: NextCompiler = HybridCompiler()
    /// Minimum seconds between injections
    let minInterval = 1.0
    /// Seconds to wait after git lock clears before auto-recovery
    let gitRecoveryDelay = 2.0

    override init() {
        super.init()
        // Extend FileWatcher pattern to detect git lock files
        FileWatcher.INJECTABLE_PATTERN = try! NSRegularExpression(
            pattern: "[^~]\\.(mm?|cpp|swift|storyboard|xib|lock)$")
    }

    /// Called from file watcher when file is edited.
    override func inject(source: String) {
        // Detect git lock files - record path and time for later checking
        if source.hasSuffix(".lock") &&
           source.contains("/.git/") {
            Self.gitLockPath = source
            Self.lockDetectedTime = Date().timeIntervalSince1970
            return
        }

        // Check for auto-recovery from git operations
        if Self.isRepositoryLocked {
            // Check if enough time has passed since lock detection
            if let lockTime = Self.lockDetectedTime,
               Date().timeIntervalSince1970 - lockTime > gitRecoveryDelay,
               Self.gitLockPath == nil || !FileManager.default.fileExists(atPath: Self.gitLockPath!) {
                // Git operation completed - auto-recover
                log("🔄 Git operation completed - auto-recovering and clearing cache")
                Self.isRepositoryLocked = false
                Self.lockDetectedTime = nil
                
                // Clear all caches as DerivedData likely changed
                MonitorXcode.runningXcode?.recompiler.clearCache()
                liteRecompiler.clearCache()
                FrontendServer.clearAllCaches()
                Unhider.unhiddens.removeAll()
                Unhider.hasAutoUnhidden = false
                
                // Trigger auto-recovery: re-inject last successfully injected file (if enabled)
                if Defaults.autoRecoveryEnabled,
                   let lastSource = NextCompiler.lastInjectedSource,
                   FileManager.default.fileExists(atPath: lastSource) {
                    
                    // Verify client is connected before attempting recovery
                    guard InjectionServer.currentClient != nil else {
                        log("⚠️ Git recovery skipped: No client connected. App may need to be relaunched.")
                        log("✅ Cache cleared - injection ready when app reconnects.")
                        return
                    }
                    
                    log("🔄 Auto-recovering: triggering re-injection of last file")
                    // Add to pending queue to trigger recompilation
                    Self.pendingFilesChanged.append(lastSource)
                    NextCompiler.compileQueue.async { self.injectNext() }
                    return
                }
                
                log("✅ Cache cleared - injection ready. \(Defaults.autoRecoveryEnabled ? "Auto-recovery will activate on next file save." : "Save a file to rebuild compilation info.")")
            } else {
                // Still locked - skip processing
                return
            }
        }

        // Check if source file is changing while git lock still exists
        if let lockPath = Self.gitLockPath {
            if FileManager.default.fileExists(atPath: lockPath) {
                // Source files changing while git lock exists = branch switch/merge/rebase
                Self.isRepositoryLocked = true
                Self.pendingFilesChanged.removeAll()
                log("""
                    Git operation in progress (branch switch/merge/rebase detected). \
                    File processing paused. Will auto-recover when operation completes.
                    """)
                return
            } else {
                // Lock file is gone - was probably just a commit (no recovery needed)
                Self.gitLockPath = nil
                Self.lockDetectedTime = nil
            }
        }

        guard !AppDelegate.watchers.isEmpty,
              Date().timeIntervalSince1970 - (MonitorXcode.runningXcode?
                .recompiler.lastInjected[source] ?? 0.0) > minInterval else {
            return
        }
        Self.pendingFilesChanged.append(source)
        NextCompiler.compileQueue.async { self.injectNext() }
    }

    func injectNext() {
        guard let source = (DispatchQueue.main.sync { () -> String? in
            if Self.pendingFilesChanged.isEmpty { return nil }
            let source = Self.pendingFilesChanged.removeFirst()
            if !Self.pendingFilesChanged.isEmpty {
                NextCompiler.compileQueue.async { self.injectNext() }
            }
            return source
        }) else { return }

        if let running = MonitorXcode.runningXcode,
           running.recompiler.inject(source: source) { return }

        var recompiler = liteRecompiler
        if FrontendServer.loggedFrontend != nil && source.hasSuffix(".swift") {
            recompiler = FrontendServer.frontendRecompiler()
        }
        if let why = GitIgnoreParser.shouldExclude(file: source) {
            log("Excluded \(source) as \(why)")
        } else if !recompiler.inject(source: source) {
            recompiler.pendingSource = source
        } else if !(recompiler === liteRecompiler) {
            FrontendServer.writeCache()
        }
    }
}

class HybridCompiler: NextCompiler {
    /// Legacy log parsing version of recomilation
    var liteRecompiler = Recompiler()

    override func recompile(source: String, platform: String) ->  String? {
        return liteRecompiler.recompile(source: source, platformFilter:
                                            "SDKs/"+platform, dylink: false)
    }
}
