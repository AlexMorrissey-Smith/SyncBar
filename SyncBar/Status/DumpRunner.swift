import Foundation

/// Runs `fileproviderctl dump`, one at a time.
///
/// Each dump makes the sync daemon do several seconds of work, so dumps are
/// serialised, rate-limited per domain, and cut off after a timeout. Reading
/// stops as soon as the header is parsed; the rest of a large domain's dump
/// (often hundreds of thousands of lines) is never read.
actor DumpRunner {
    static let executable = URL(filePath: "/usr/bin/fileproviderctl")
    static let timeout: TimeInterval = 45
    static let minimumInterval: TimeInterval = 60

    private var lastRun: [String: Date] = [:]
    private var isRunning = false

    /// True when a dump for `domain` is allowed now.
    func canRun(_ domain: String, now: Date = Date()) -> Bool {
        guard !isRunning else { return false }
        guard let last = lastRun[domain] else { return true }
        return now.timeIntervalSince(last) >= Self.minimumInterval
    }

    /// Dumps one domain. Returns nil if a dump is already running, the domain
    /// was dumped less than a minute ago, or the dump failed.
    func dump(_ domain: String) async -> FileProviderSnapshot? {
        guard canRun(domain) else { return nil }
        isRunning = true
        lastRun[domain] = Date()
        defer { isRunning = false }
        return await Task.detached(priority: .utility) { Self.runBlocking(domain) }.value
    }

    private static func runBlocking(_ domain: String) -> FileProviderSnapshot? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["dump", domain]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let deadline = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

        var parser = FileProviderDumpParser()
        var pending = Data()
        let reader = pipe.fileHandleForReading
        while !parser.isComplete {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                parser.consume(line)
                if parser.isComplete { break }
            }
        }

        deadline.cancel()
        if process.isRunning { process.terminate() }
        try? reader.close()
        process.waitUntilExit()

        // A dump that never reached the sync engine header (timeout, unknown
        // domain) tells us nothing reliable.
        return parser.isComplete ? parser.snapshot : nil
    }
}
