import Darwin
import EIZOHID
import Foundation
import os

public enum HelperError: Error, LocalizedError, Sendable {
    case missingExecutable, timedOut, invalidOutput, outputTooLarge
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: "読み取りプログラムが見つかりません。アプリをビルドし直してください。"
        case .timedOut: "モニターの応答が制限時間内に得られませんでした。"
        case .invalidOutput: "モニターの読み取り結果を解釈できませんでした。"
        case .outputTooLarge: "読み取り結果がサイズの上限を超えました。"
        case .failed(let message): message
        }
    }
}

public struct HelperClient: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) { self.executableURL = executableURL }

    public static func bundled() throws -> HelperClient {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/eizo-usage")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw HelperError.missingExecutable
        }
        return HelperClient(executableURL: url)
    }

    @concurrent
    public func read() async throws -> [MonitorUsageReport] {
        let result = try await HelperCommand(executableURL: executableURL, arguments: ["--json"]).run()
        guard result.reason == .exit, result.status == 0 else {
            if result.reason == .uncaughtSignal && result.status == SIGALRM { throw HelperError.timedOut }
            let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("not found. Check the monitor's USB") {
                throw HelperError.failed("CS2731が見つかりません。モニターのUSB接続を確認してください。")
            }
            if detail.contains("ColorNavigator 7 is in application mode") {
                throw HelperError.failed("ColorNavigator 7の画面が開いているため、取得を中止しました。Agentは起動したままで構いません。")
            }
            throw HelperError.failed(detail.isEmpty ? "モニターの読み取りに失敗しました。" : detail)
        }
        do { return try JSONDecoder().decode([MonitorUsageReport].self, from: result.stdout) }
        catch { throw HelperError.invalidOutput }
    }
}

struct HelperResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let reason: Process.TerminationReason
}

/// A single owned child process. The lock serializes launch/cancel/timeout, including
/// cancellation before launch. All blocking work and pipe draining run off the main actor.
final class HelperCommand: Sendable {
    private struct State: Sendable {
        let process: Process
        var cancelled = false
    }
    private let state: OSAllocatedUnfairLock<State>
    private let timeout: TimeInterval

    init(executableURL: URL, arguments: [String], timeout: TimeInterval = 20) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        state = OSAllocatedUnfairLock(initialState: State(process: process))
        self.timeout = timeout
    }

    func run() async throws -> HelperResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try self.execute()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        state.withLock { state in
            state.cancelled = true
            if state.process.isRunning { kill(state.process.processIdentifier, SIGKILL) }
        }
    }

    private func execute() throws -> HelperResult {
        let stdout = Pipe()
        let stderr = Pipe()
        let exitSignal = DispatchSemaphore(value: 0)
        try state.withLock { state in
            guard !state.cancelled else { throw CancellationError() }
            state.process.standardOutput = stdout
            state.process.standardError = stderr
            state.process.standardInput = FileHandle.nullDevice
            state.process.terminationHandler = { _ in exitSignal.signal() }
            try state.process.run()
        }
        // Only the child keeps the writing ends; EOF follows its termination.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let output = PipeCapture(stdout.fileHandleForReading)
        let errors = PipeCapture(stderr.fileHandleForReading)
        output.start()
        errors.start()
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            state.withLock { state in
                if state.process.isRunning { kill(state.process.processIdentifier, SIGKILL) }
            }
            exitSignal.wait()
        }
        let outputData = output.finish()
        let errorData = errors.finish()
        return try state.withLock { state in
            if state.cancelled { throw CancellationError() }
            if timedOut { throw HelperError.timedOut }
            guard let outputData, let errorData else { throw HelperError.outputTooLarge }
            return HelperResult(stdout: outputData, stderr: errorData,
                                status: state.process.terminationStatus, reason: state.process.terminationReason)
        }
    }
}

/// Each buffer is protected by a lock; completion is signaled after EOF.
/// Excess data is drained without retaining it, so neither pipe can deadlock the child.
private final class PipeCapture: Sendable {
    private let handle: FileHandle
    private let completion = DispatchSemaphore(value: 0)
    private let data = OSAllocatedUnfairLock<Data?>(initialState: Data())
    init(_ handle: FileHandle) { self.handle = handle }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? handle.close(); completion.signal() }
            do {
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    data.withLock { data in
                        if let count = data?.count, count + chunk.count <= 2 * 1_024 * 1_024 {
                            data?.append(chunk)
                        } else { data = nil }
                    }
                }
            } catch { data.withLock { $0 = nil } }
        }
    }

    func finish() -> Data? {
        completion.wait()
        return data.withLock { $0 }
    }
}
