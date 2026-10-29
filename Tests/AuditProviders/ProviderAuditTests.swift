import Darwin
import Foundation

/// Checks ProcessRunner against real child processes, and WhisperCoreMLArchive against deflated
/// archives written by zip(1) and Python. macOS only.
@main
struct ProviderAuditTests {
    private static var checks = 0
    private static var failures = 0

    static func main() async {
        await checkConcurrentPipes()
        await checkExitStatusAndLaunchFailure()
        await checkTimeout()
        await checkCancellationKillsOrphanedChild()
        await checkArchiveInstall()
        print("\(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if condition() {
            print("PASS: \(description)")
        } else {
            failures += 1
            fputs("FAIL: \(description)\n", stderr)
        }
    }

    private static let sh = URL(fileURLWithPath: "/bin/sh")

    private static func checkConcurrentPipes() async {
        // 4 MiB through cat exceeds every pipe buffer in both directions.
        let input = Data(repeating: 0x61, count: 4 << 20)
        let echoed = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: input,
            timeout: 20, outputLimit: 1 << 20)
        expect(echoed?.succeeded == true, "large stdin and stdout do not deadlock")
        expect(echoed?.stdout.count == 1 << 20 && echoed?.isStdoutTruncated == true,
               "stdout is capped at the limit and marked truncated")

        let both = try? await ProcessRunner.run(
            executableURL: sh,
            arguments: ["-c", "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"],
            timeout: 20, outputLimit: 1000)
        expect(both?.succeeded == true && both?.isStdoutTruncated == true && both?.isStderrTruncated == true,
               "full stdout and stderr drain concurrently")

        let ignored = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            standardInput: Data(count: 8 << 20), timeout: 20)
        expect(ignored?.succeeded == true, "a child that ignores stdin causes EPIPE, not SIGPIPE")
    }

    private static func checkExitStatusAndLaunchFailure() async {
        let failed = try? await ProcessRunner.run(
            executableURL: sh, arguments: ["-c", "printf out; printf err >&2; exit 3"], timeout: 10)
        expect(failed?.status == 3 && failed?.succeeded == false, "nonzero exit status is reported")
        expect(failed?.stdoutString == "out" && failed?.stderrString == "err", "stdout and stderr stay separate")

        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/voce-audit"), arguments: [], timeout: 5)
            expect(false, "launch failure throws")
        } catch let error as ProcessRunner.Failure {
            if case .launchFailed = error { expect(true, "launch failure throws launchFailed") }
            else { expect(false, "launch failure throws launchFailed") }
        } catch {
            expect(false, "launch failure throws launchFailed")
        }
    }

    private static func checkTimeout() async {
        let start = Date()
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3,
                terminationGracePeriod: 0.5)
            expect(false, "timeout throws")
        } catch {
            expect(error as? ProcessRunner.Failure == .timedOut, "timeout throws timedOut")
        }
        expect(Date().timeIntervalSince(start) < 5, "timeout returns promptly")
    }

    /// The shell exits on SIGTERM while its child ignores SIGTERM and is orphaned.
    /// The child must still receive SIGKILL after the grace period.
    private static func checkCancellationKillsOrphanedChild() async {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-audit-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let task = Task {
            try await ProcessRunner.run(
                executableURL: sh,
                arguments: ["-c", "(trap '' TERM; exec /bin/sleep 30) & echo $! > \"$1\"; wait", "sh", pidFile.path],
                timeout: 60,
                terminationGracePeriod: 0.5)
        }

        var childPID: pid_t?
        for _ in 0..<100 where childPID == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
            childPID = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let childPID else {
            expect(false, "test child started")
            task.cancel()
            return
        }
        expect(kill(childPID, 0) == 0, "TERM-ignoring child is running before cancellation")

        task.cancel()
        let result = await task.result
        if case .failure(let error) = result {
            expect(error is CancellationError, "cancellation throws CancellationError")
        } else {
            expect(false, "cancellation throws CancellationError")
        }

        var childGone = false
        for _ in 0..<60 where !childGone {
            try? await Task.sleep(nanoseconds: 50_000_000)
            childGone = kill(childPID, 0) != 0 && errno == ESRCH
        }
        expect(childGone, "orphaned child that ignores SIGTERM is killed after the grace period")
        if !childGone { _ = kill(childPID, SIGKILL) }
    }

    private static func checkArchiveInstall() async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("voce-audit-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let name = "ggml-base-encoder.mlmodelc"
        let source = root.appendingPathComponent("source")
        let staging = root.appendingPathComponent("staging")
        let destination = root.appendingPathComponent("models")
        try? fileManager.createDirectory(at: source.appendingPathComponent("\(name)/weights"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: destination.appendingPathComponent(name), withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: destination.appendingPathComponent("\(name)/stale"))
        // Compressible content, so zip(1) stores it deflated and the inflate path runs.
        let weights = Data(String(repeating: "voce weights ", count: 50_000).utf8)
        try? weights.write(to: source.appendingPathComponent("\(name)/weights/weight.bin"))

        let goodZip = root.appendingPathComponent("good.zip")
        _ = try? await ProcessRunner.run(
            executableURL: sh, arguments: ["-c", "cd \"$1\" && /usr/bin/zip -qry \"$2\" \"$3\"", "sh", source.path, goodZip.path, name],
            timeout: 20)
        let installed = try? await WhisperCoreMLArchive.install(
            zipURL: goodZip, archiveDirectoryName: name, installedName: name, stagingDirectory: staging,
            destinationDirectory: destination)
        expect(installed == destination.appendingPathComponent(name, isDirectory: true), "valid archive installs the encoder")
        expect((try? Data(contentsOf: destination.appendingPathComponent("\(name)/weights/weight.bin"))) == weights
               && !fileManager.fileExists(atPath: destination.appendingPathComponent("\(name)/stale").path),
               "deflated entries inflate exactly and replace the previous encoder")

        // A symlink pointing outside the encoder must stop installation before extraction.
        _ = symlink("/etc", source.appendingPathComponent("\(name)/escape").path)
        let symlinkZip = root.appendingPathComponent("symlink.zip")
        _ = try? await ProcessRunner.run(
            executableURL: sh, arguments: ["-c", "cd \"$1\" && /usr/bin/zip -qry \"$2\" \"$3\"", "sh", source.path, symlinkZip.path, name],
            timeout: 20)
        do {
            _ = try await WhisperCoreMLArchive.install(
                zipURL: symlinkZip, archiveDirectoryName: name, installedName: name, stagingDirectory: staging,
                destinationDirectory: destination)
            expect(false, "archive with a symlink is rejected")
        } catch {
            expect(error as? WhisperCoreMLArchive.ArchiveError == .unsafeEntry("\(name)/escape"),
                   "archive with a symlink is rejected")
        }
        expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("\(name)/escape").path),
               "rejected archive leaves the installed encoder untouched")

        // zip(1) cannot store "../" names, so Python writes the traversal entry directly.
        let traversalZip = root.appendingPathComponent("traversal.zip")
        let script = "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w') as z:\n"
            + "    z.writestr(sys.argv[2] + '/model.mil', 'x')\n    z.writestr('../voce-audit-escape', 'x')\n"
        _ = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-I", "-c", script, traversalZip.path, name], timeout: 20)
        do {
            _ = try await WhisperCoreMLArchive.install(
                zipURL: traversalZip, archiveDirectoryName: name, installedName: name, stagingDirectory: staging,
                destinationDirectory: destination)
            expect(false, "archive with a traversal entry is rejected")
        } catch {
            expect(error as? WhisperCoreMLArchive.ArchiveError == .unsafeEntry("../voce-audit-escape"),
                   "archive with a traversal entry is rejected")
        }
        expect(!fileManager.fileExists(atPath: staging.deletingLastPathComponent()
                   .appendingPathComponent("voce-audit-escape").path),
               "traversal entry is never written")
    }
}
