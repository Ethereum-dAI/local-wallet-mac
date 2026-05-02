import CSpawn
import Darwin
import Foundation

public struct SpawnError: Error, LocalizedError {
    public let errno: Int32

    public init(errno: Int32) {
        self.errno = errno
    }

    public var errorDescription: String? {
        String(cString: strerror(errno))
    }

    public var localizedDescription: String {
        errorDescription ?? "posix_spawn failed with errno \(errno)"
    }
}

public func spawnHelper(execPath: String, readyWrite: Int32, aliveRead: Int32) throws -> pid_t {
    var pid = pid_t()
    let result = execPath.withCString { execPathPointer in
        wallet_node_spawn_helper(execPathPointer, readyWrite, aliveRead, &pid)
    }

    if result != 0 {
        throw SpawnError(errno: result)
    }

    return pid
}
