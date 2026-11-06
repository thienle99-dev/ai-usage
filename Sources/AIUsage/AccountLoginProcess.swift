import Foundation

@MainActor protocol AccountLoginProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    func send(_ data: Data)
}

@MainActor protocol AccountLoginProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        output: @escaping @MainActor (Data) -> Void,
        termination: @escaping @MainActor (Int32) -> Void
    ) throws -> any AccountLoginProcessHandle
}

@MainActor struct FoundationAccountLoginProcessLauncher: AccountLoginProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        output: @escaping @MainActor (Data) -> Void,
        termination: @escaping @MainActor (Int32) -> Void
    ) throws -> any AccountLoginProcessHandle {
        let process = Process()
        let input = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let reader = outputPipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in output(data) }
        }
        process.terminationHandler = { terminated in
            reader.readabilityHandler = nil
            Task { @MainActor in termination(terminated.terminationStatus) }
        }
        try process.run()
        return FoundationAccountLoginProcessHandle(process: process, input: input)
    }
}

@MainActor private final class FoundationAccountLoginProcessHandle: AccountLoginProcessHandle {
    private let process: Process
    private let input: Pipe

    init(process: Process, input: Pipe) {
        self.process = process
        self.input = input
    }

    var isRunning: Bool { process.isRunning }
    func terminate() { if process.isRunning { process.terminate() } }
    func send(_ data: Data) { input.fileHandleForWriting.write(data) }
}
