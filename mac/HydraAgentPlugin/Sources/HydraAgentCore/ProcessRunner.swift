import Foundation

struct ProcessOutput {
    var status: Int32
    var text: String
    var timedOut: Bool
}

enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ProcessOutput(status: -1, text: error.localizedDescription, timedOut: false)
        }

        let lock = NSLock()
        var collected = Data()
        let group = DispatchGroup()

        func collect(_ pipe: Pipe) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                collected.append(data)
                lock.unlock()
                group.leave()
            }
        }
        collect(stdout)
        collect(stderr)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)

        lock.lock()
        let data = collected
        lock.unlock()
        let text = String(data: data, encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, text: text, timedOut: timedOut)
    }
}
