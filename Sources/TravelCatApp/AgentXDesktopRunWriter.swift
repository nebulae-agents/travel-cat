import AppKit
import Darwin
import Foundation
import TravelStorage
@preconcurrency import Network

final class AgentXWriterRootLease {
    private let fd: Int32
    init(root: URL) throws {
        let path = root.path
        guard let canonical = realpath(path, nil) else { throw AgentXError.unsafePath }
        defer { free(canonical) }
        guard String(cString: canonical) == path else { throw AgentXError.unsafePath }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentXError.unsafePath }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw AgentXError.unsafePath
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            if busy { throw AgentXError.invalid("数据目录正在使用，请先退出旧 agentxd 或另一份桌面客户端，再重新打开。") }
            throw AgentXError.unavailable
        }
        fd = descriptor
    }
    deinit { close(fd) }
}
