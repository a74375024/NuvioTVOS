import Foundation
import Darwin

/// Keeps a small record of what the app was doing when it crashed, for the
/// Live TV playback log export. The app's error output (where Swift writes
/// "Fatal error: …") goes to a file in Caches, along with short breadcrumbs
/// and, on a crash, the stack. The session that crashed is kept until the
/// next crash. Links and anything that looks like a login are removed when
/// the report is exported.
enum CrashRecorder {
    private static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Diagnostics", isDirectory: true)
    }
    private static var sessionFile: URL { folder.appendingPathComponent("session.log") }
    private static var crashFile: URL { folder.appendingPathComponent("crash-last.log") }
    private static var previousFile: URL { folder.appendingPathComponent("session-previous.log") }
    private static var started = false
    private static var trimTimer: DispatchSourceTimer?

    /// Called once at launch.
    static func start() {
        #if DEBUG
        return
        #else
        guard !started else { return }
        started = true
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // The previous session crashed: keep it.
        if let data = try? Data(contentsOf: sessionFile), let text = String(data: data, encoding: .utf8),
           text.contains("=== CRASH") || text.contains("Fatal error") || text.contains("Uncaught exception") {
            try? manager.removeItem(at: crashFile)
            try? data.write(to: crashFile, options: .atomic)
        }
        // Ended some other way (killed for memory or for being stuck, which
        // can't be caught): keep it as the previous session.
        try? manager.removeItem(at: previousFile)
        try? manager.moveItem(at: sessionFile, to: previousFile)
        manager.createFile(atPath: sessionFile.path, contents: nil)
        let fd = open(sessionFile.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
        setvbuf(stderr, nil, _IONBF, 0)

        NSSetUncaughtExceptionHandler { exception in
            let text = "\n=== CRASH Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            fputs(text, stderr)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashRecorderSignal)
        }

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        note("=== SESSION START \(version)")

        // Keep the file small if something chatters on the error output.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            let size = (try? FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 4 * 1024 * 1024 {
                ftruncate(STDERR_FILENO, 0)
                note("(log trimmed)")
            }
        }
        timer.resume()
        trimTimer = timer
        startWatchdog()
        #endif
    }

    /// Notes when the main thread stops responding (stuck work gets the app
    /// killed without a crash), and memory every so often.
    private static func startWatchdog() {
        let thread = Thread {
            var lastMemory = 0
            var tick = 0
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                var waited = 0
                while answered.wait(timeout: .now() + 1) == .timedOut {
                    waited += 1
                    if waited == 2 || waited % 5 == 0 { note("main thread stuck \(waited) s (\(memoryMB()) MB)") }
                }
                if waited >= 2 { note("main thread back after \(Int(Date().timeIntervalSince(sent))) s") }
                tick += 1
                if tick % 10 == 0 {
                    let memory = memoryMB()
                    if abs(memory - lastMemory) >= 75 {
                        note("memory \(memory) MB")
                        lastMemory = memory
                    }
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.name = "CrashRecorder.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// The app's memory footprint in MB.
    static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// A one-line breadcrumb ("events: open, 42 events").
    static func note(_ text: String) {
        #if !DEBUG
        guard started else { return }
        fputs("[\(clock.string(from: Date()))] \(text)\n", stderr)
        #endif
    }

    /// The last crash and the end of this session, cleaned, as comment lines
    /// for the bottom of the playback log.
    static func report() -> String {
        var sections: [String] = []
        if let text = try? String(contentsOf: crashFile, encoding: .utf8) {
            sections.append("LAST CRASH")
            sections.append(contentsOf: tail(text, lines: 400))
        } else {
            sections.append("LAST CRASH: none recorded")
        }
        if let text = try? String(contentsOf: previousFile, encoding: .utf8) {
            sections.append("PREVIOUS SESSION (end)")
            sections.append(contentsOf: tail(text, lines: 200))
        }
        if let text = try? String(contentsOf: sessionFile, encoding: .utf8) {
            sections.append("THIS SESSION (end)")
            sections.append(contentsOf: tail(text, lines: 120))
        }
        return sections.map { "# " + scrub($0) }.joined(separator: "\n") + "\n"
    }

    private static func tail(_ text: String, lines: Int) -> [String] {
        Array(text.components(separatedBy: "\n").suffix(lines))
    }

    private static let scrubPatterns: [(String, String)] = [
        ("[A-Za-z][A-Za-z0-9+.-]*://\\S+", "<link>"),
        ("\\S*/(live|movie|series|timeshift)/\\S+", "<link>"),
        ("\\S+\\.(m3u8?|ts|mpd|mp4|mkv)(\\?\\S*)?\\b", "<link>"),
        ("(?i)(user(name)?|pass(word)?|token|key|auth)=\\S+", "$1=<hidden>"),
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>")
    ]

    static func scrub(_ line: String) -> String {
        var value = line
        for (pattern, template) in scrubPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value),
                                                   withTemplate: template)
        }
        return value
    }
}

/// Signal handler: writes the stack to the error output (the session file),
/// then lets the crash continue as usual.
private func crashRecorderSignal(_ sig: Int32) {
    let text = "\n=== CRASH signal \(sig)\n" + Thread.callStackSymbols.joined(separator: "\n") + "\n"
    text.withCString { pointer in _ = write(STDERR_FILENO, pointer, strlen(pointer)) }
    signal(sig, SIG_DFL)
    raise(sig)
}
