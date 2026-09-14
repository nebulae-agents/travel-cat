import Darwin
import Foundation

/// Reads model-selected bytes only beneath a separately configured trusted directory.
struct JourneyTestGeneratedImageReader: Sendable {
  enum Rejection: Error { case unsafePath, unsafeFile, tooLarge, changedFile }
  let allowedRoot: URL
  let maximumBytes: Int
  let beforeRevalidation: @Sendable () throws -> Void

  init(allowedRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/generated_images"),
       maximumBytes: Int = 15 * 1024 * 1024,
       beforeRevalidation: @escaping @Sendable () throws -> Void = {}) {
    self.allowedRoot = allowedRoot
    self.maximumBytes = min(maximumBytes, 15 * 1024 * 1024)
    self.beforeRevalidation = beforeRevalidation
  }

  func read(path: String) throws -> Data {
    try Task.checkCancellation()
    guard allowedRoot.isFileURL, let resolved = realpath(allowedRoot.path, nil) else { throw Rejection.unsafePath }
    let root = String(cString: resolved)
    free(resolved)
    guard maximumBytes > 0, path.hasPrefix(root + "/"), !path.contains("\0") else { throw Rejection.unsafePath }
    let components = path.dropFirst().components(separatedBy: "/")
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Rejection.unsafePath }
    struct Entry { let fd: Int32; let parent: Int32; let name: String; let snapshot: stat }
    var entries: [Entry] = []
    defer { for entry in entries.reversed() { close(entry.fd) } }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Rejection.unsafePath }
    var initial = stat()
    guard fstat(descriptor, &initial) == 0 else { close(descriptor); throw Rejection.unsafeFile }
    entries.append(.init(fd: descriptor, parent: -1, name: "", snapshot: initial))
    for (index, component) in components.enumerated() {
      let leaf = index == components.count - 1
      let child = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (leaf ? 0 : O_DIRECTORY))
      guard child >= 0 else { throw Rejection.unsafeFile }
      var info = stat()
      guard fstat(child, &info) == 0 else { close(child); throw Rejection.unsafeFile }
      entries.append(.init(fd: child, parent: descriptor, name: component, snapshot: info))
      descriptor = child
      if leaf {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Rejection.unsafeFile }
        guard info.st_size > 0, info.st_size <= maximumBytes else { throw Rejection.tooLarge }
      }
    }
    func bytes() throws -> Data {
      guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw Rejection.unsafeFile }
      var result = Data(), buffer = [UInt8](repeating: 0, count: min(65536, maximumBytes + 1))
      while result.count <= maximumBytes {
        try Task.checkCancellation()
        let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - result.count))
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw Rejection.unsafeFile }
        if count == 0 { return result }
        result.append(buffer, count: count)
      }
      throw Rejection.tooLarge
    }
    func unchanged(_ a: stat, _ b: stat, leaf: Bool) -> Bool {
      a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        (!leaf || (a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
          a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
          a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec))
    }
    func revalidate() throws {
      for (index, entry) in entries.enumerated() {
        var current = stat(), linked = stat()
        let leaf = index == entries.count - 1
        guard fstat(entry.fd, &current) == 0, unchanged(entry.snapshot, current, leaf: leaf) else { throw Rejection.changedFile }
        if entry.parent >= 0 {
          guard fstatat(entry.parent, entry.name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                unchanged(entry.snapshot, linked, leaf: leaf) else { throw Rejection.changedFile }
        }
      }
    }
    let data = try bytes()
    guard Int64(data.count) == entries.last?.snapshot.st_size else { throw Rejection.changedFile }
    try beforeRevalidation()
    try revalidate()
    guard try bytes() == data else { throw Rejection.changedFile }
    try revalidate()
    try Task.checkCancellation()
    return data
  }
}
