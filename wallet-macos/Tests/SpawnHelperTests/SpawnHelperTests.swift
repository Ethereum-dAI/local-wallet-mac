import Darwin
import Foundation
import SpawnHelper
import XCTest

final class SpawnHelperTests: XCTestCase {
    func testSuspendedSpawnDoesNotExecuteUntilResumed() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("spawn-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let scriptURL = temporaryDirectory.appendingPathComponent("ready-helper.sh")
        let script = """
        #!/bin/sh
        printf 'ready\\n' >&3
        cat <&5 >/dev/null
        cat <&4 >/dev/null
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        XCTAssertEqual(chmod(scriptURL.path, S_IRUSR | S_IWUSR | S_IXUSR), 0)

        var readyPipe: [Int32] = [-1, -1]
        var alivePipe: [Int32] = [-1, -1]
        var secretPipe: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&readyPipe), 0)
        XCTAssertEqual(pipe(&alivePipe), 0)
        XCTAssertEqual(pipe(&secretPipe), 0)

        var childPid: pid_t = -1
        var childReaped = false
        defer {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&alivePipe[1])
            closeIfOpen(&secretPipe[0])
            closeIfOpen(&secretPipe[1])

            if childPid > 0 && !childReaped {
                kill(childPid, SIGKILL)
                _ = waitChildWithTimeout(pid: childPid, timeout: 1)
            }
        }

        try setCloseOnExec(readyPipe[0])
        try setCloseOnExec(readyPipe[1])
        try setCloseOnExec(alivePipe[0])
        try setCloseOnExec(alivePipe[1])
        try setCloseOnExec(secretPipe[0])
        try setCloseOnExec(secretPipe[1])

        childPid = try spawnHelper(
            execPath: scriptURL.path,
            readyWrite: readyPipe[1],
            aliveRead: alivePipe[0],
            secretRead: secretPipe[0],
            startSuspended: true
        )

        closeIfOpen(&readyPipe[1])
        closeIfOpen(&alivePipe[0])
        closeIfOpen(&secretPipe[0])

        XCTAssertFalse(
            hasReadableData(fd: readyPipe[0], timeoutMilliseconds: 150),
            "a suspended helper must not execute before validation and resume"
        )
        var status: Int32 = 0
        XCTAssertEqual(waitpid(childPid, &status, WNOHANG), 0)

        try resumeHelper(pid: childPid)
        let readyData = readLineWithTimeout(fd: readyPipe[0], timeout: 2)
        XCTAssertEqual(String(data: readyData, encoding: .utf8), "ready\n")

        closeIfOpen(&secretPipe[1])
        closeIfOpen(&alivePipe[1])
        let exitStatus = waitChildWithTimeout(pid: childPid, timeout: 2)
        childReaped = true
        XCTAssertEqual(exitStatus, 0)
    }

    func testSpawnDaemonAndReceiveReadyEvent() throws {
        let daemonBinPath = defaultDaemonBinPath()
        guard FileManager.default.isExecutableFile(atPath: daemonBinPath) else {
            throw XCTSkip("Missing wallet-node binary at \(daemonBinPath). Run `cargo build -p wallet-node`.")
        }

        let tempHome = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wln-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempHome)
        }
        guard canBindUnixSocket(at: tempHome.appendingPathComponent("preflight.sock").path) else {
            throw XCTSkip("AF_UNIX bind is unavailable in this environment.")
        }

        let oldHome = getenv("HOME").map { String(cString: $0) }
        let oldXDGDataHome = getenv("XDG_DATA_HOME").map { String(cString: $0) }
        setenv("HOME", tempHome.path, 1)
        setenv("XDG_DATA_HOME", tempHome.appendingPathComponent(".local/share").path, 1)
        defer {
            restoreEnv("HOME", oldHome)
            restoreEnv("XDG_DATA_HOME", oldXDGDataHome)
        }

        var readyPipe: [Int32] = [-1, -1]
        var alivePipe: [Int32] = [-1, -1]
        var secretPipe: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&readyPipe), 0)
        XCTAssertEqual(pipe(&alivePipe), 0)
        XCTAssertEqual(pipe(&secretPipe), 0)

        var childPid: pid_t = -1
        var childReaped = false
        defer {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&alivePipe[1])
            closeIfOpen(&secretPipe[0])
            closeIfOpen(&secretPipe[1])

            if childPid > 0 && !childReaped {
                let status = waitChildWithTimeout(pid: childPid, timeout: 1)
                if status == Int32.min {
                    kill(childPid, SIGKILL)
                    _ = waitChildWithTimeout(pid: childPid, timeout: 1)
                }
            }
        }

        try setCloseOnExec(readyPipe[0])
        try setCloseOnExec(readyPipe[1])
        try setCloseOnExec(alivePipe[0])
        try setCloseOnExec(alivePipe[1])
        try setCloseOnExec(secretPipe[0])
        try setCloseOnExec(secretPipe[1])

        childPid = try spawnHelper(
            execPath: daemonBinPath,
            readyWrite: readyPipe[1],
            aliveRead: alivePipe[0],
            secretRead: secretPipe[0]
        )

        closeIfOpen(&readyPipe[1])
        closeIfOpen(&alivePipe[0])
        closeIfOpen(&secretPipe[0])
        let payload = #"{"keys":[]}"#
        writeAll(fd: secretPipe[1], data: Data(payload.utf8))
        closeIfOpen(&secretPipe[1])

        let readyData = readLineWithTimeout(fd: readyPipe[0], timeout: 5)
        XCTAssertFalse(readyData.isEmpty, "ready pipe should produce a JSON line")
        let readyObject = try JSONSerialization.jsonObject(with: readyData)
        let ready = try XCTUnwrap(readyObject as? [String: Any])

        XCTAssertEqual(ready["apiVersion"] as? Int, 1)
        let token = try XCTUnwrap(ready["token"] as? String)
        XCTAssertFalse(token.isEmpty)
        let socketPath = try XCTUnwrap(ready["socketPath"] as? String)
        XCTAssertFalse(socketPath.isEmpty)

        closeIfOpen(&alivePipe[1])
        let status = waitChildWithTimeout(pid: childPid, timeout: 3)
        childReaped = true
        XCTAssertEqual(status, 0, "wallet-node should exit successfully after alive pipe EOF")
    }
}

private func hasReadableData(fd: Int32, timeoutMilliseconds: Int32) -> Bool {
    var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let result = poll(&pollFd, 1, timeoutMilliseconds)
        if result == -1 && errno == EINTR {
            continue
        }
        return result > 0 && (pollFd.revents & Int16(POLLIN | POLLHUP)) != 0
    }
}

private func readLineWithTimeout(fd: Int32, timeout: TimeInterval) -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    var data = Data()

    while Date() < deadline {
        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
        let pollResult = poll(&pollFd, 1, remainingMilliseconds)

        if pollResult == 0 {
            XCTFail("timed out waiting for ready pipe")
            return Data()
        }
        if pollResult < 0 {
            if errno == EINTR {
                continue
            }
            XCTFail("poll failed with errno \(errno)")
            return Data()
        }

        if (pollFd.revents & Int16(POLLIN | POLLHUP)) == 0 {
            XCTFail("ready pipe poll returned unexpected revents \(pollFd.revents)")
            return Data()
        }

        while true {
            var byte: UInt8 = 0
            let readCount = withUnsafeMutableBytes(of: &byte) { buffer in
                read(fd, buffer.baseAddress, 1)
            }

            if readCount == 1 {
                data.append(byte)
                if byte == UInt8(ascii: "\n") {
                    return data
                }
            } else if readCount == 0 {
                if data.isEmpty {
                    XCTFail("ready pipe closed without data")
                }
                return data
            } else if errno == EINTR {
                continue
            } else {
                XCTFail("read failed with errno \(errno)")
                return Data()
            }
        }
    }

    XCTFail("timed out waiting for ready pipe")
    return Data()
}

private func writeAll(fd: Int32, data: Data) {
    data.withUnsafeBytes { buffer in
        guard var base = buffer.baseAddress else {
            return
        }
        var remaining = data.count
        while remaining > 0 {
            let written = Darwin.write(fd, base, remaining)
            if written <= 0 {
                return
            }
            base = base.advanced(by: written)
            remaining -= written
        }
    }
}

private func waitChildWithTimeout(pid: pid_t, timeout: TimeInterval) -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return status
        }
        if result == -1 && errno != EINTR {
            return -1
        }

        usleep(10_000)
    }

    return Int32.min
}

private func defaultDaemonBinPath() -> String {
    if let override = ProcessInfo.processInfo.environment["WALLET_NODE_BIN"], !override.isEmpty {
        return override
    }

    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let daemonTargetRoot = packageRoot
        .deletingLastPathComponent()
        .appendingPathComponent("local-wallet-daemon/target", isDirectory: true)
    let candidates = [
        daemonTargetRoot.appendingPathComponent("debug/wallet-node").path,
        daemonTargetRoot.appendingPathComponent("release/wallet-node").path,
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
}

private func setCloseOnExec(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFD)
    if flags == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func closeIfOpen(_ fd: inout Int32) {
    if fd >= 0 {
        close(fd)
        fd = -1
    }
}

private func restoreEnv(_ name: String, _ value: String?) {
    if let value {
        setenv(name, value, 1)
    } else {
        unsetenv(name)
    }
}

private func canBindUnixSocket(at path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd == -1 {
        return false
    }
    defer {
        close(fd)
        unlink(path)
    }

    var address = sockaddr_un()
    let pathLength = path.utf8.count
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    if pathLength >= maxPathLength {
        return false
    }

    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &address.sun_path) { destination in
        path.withCString { source in
            memcpy(destination.baseAddress, source, pathLength + 1)
        }
    }

    let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathLength + 1)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            bind(fd, socketAddress, addressLength)
        }
    }

    return result == 0
}
