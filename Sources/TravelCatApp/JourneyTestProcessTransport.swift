import Darwin
import Foundation

enum JourneyTestProcessTransportError: Error, Equatable, Sendable {
  case invalidExecutable, invalidLimits
  case launchFailed(Int32)
  case timedOut, cancelled, outputLimitExceeded, streamReadFailed
}

final class JourneyTestProcessTransport: @unchecked Sendable {
  private let executableURL: URL
  private let timeout: TimeInterval
  private let maxOutputBytes: Int
  init(executableURL: URL, timeout: TimeInterval, maxOutputBytes: Int) throws {
    guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else { throw JourneyTestProcessTransportError.invalidExecutable }
    guard timeout.isFinite, timeout > 0, maxOutputBytes > 0 else {
      throw JourneyTestProcessTransportError.invalidLimits
    }
    self.executableURL = executableURL
    self.timeout = timeout
    self.maxOutputBytes = maxOutputBytes
  }
  func run(
    arguments: [String], environment: [String: String], inputURL: URL,
    cancellation: JourneyTestCancellation
  ) throws {
    if cancellation.cancelled { throw JourneyTestProcessTransportError.cancelled }
    let stdoutPipe = try makePipe()
    var stderrPipe: PipeDescriptors?
    var parentOwnsAllPipeEnds = true
    defer {
      if parentOwnsAllPipeEnds {
        close(stdoutPipe.read)
        close(stdoutPipe.write)
        if let stderrPipe {
          close(stderrPipe.read)
          close(stderrPipe.write)
        }
      }
    }
    stderrPipe = try makePipe()
    guard let stderrPipe else { throw JourneyTestProcessTransportError.launchFailed(EIO) }
    let input = try FileHandle(forReadingFrom: inputURL)
    defer { try? input.close() }
    let pid = try spawn(
      arguments: arguments, environment: environment, input: input.fileDescriptor,
      stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    close(stdoutPipe.write)
    close(stderrPipe.write)
    let collector = Collector(limit: maxOutputBytes)
    let readers = DispatchGroup()
    startReader(stdoutPipe.read, collector, readers, pid)
    startReader(stderrPipe.read, collector, readers, pid)
    parentOwnsAllPipeEnds = false
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var status: Int32 = 0
    var reaped = false
    var failure: JourneyTestProcessTransportError?
    while !reaped || exists(pid) {
      if !reaped, waitpid(pid, &status, WNOHANG) == pid { reaped = true }
      let state = collector.snapshot()
      if cancellation.cancelled {
        failure = .cancelled
        stop(pid)
        break
      }
      if state.exceeded {
        failure = .outputLimitExceeded
        stop(pid)
        break
      }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        failure = .timedOut
        stop(pid)
        break
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    if !reaped { _ = waitpid(pid, &status, 0) }
    if readers.wait(timeout: .now() + 2) == .timedOut { failure = failure ?? .streamReadFailed }
    let state = collector.snapshot()
    if state.readFailed { failure = failure ?? .streamReadFailed }
    if state.exceeded { failure = .outputLimitExceeded }
    if let failure { throw failure }
    let exitStatus = Self.exitStatus(status)
    guard exitStatus == 0 else { throw JourneyTestProcessTransportError.launchFailed(exitStatus) }
  }
  private typealias PipeDescriptors = (read: Int32, write: Int32)
  private func makePipe() throws -> PipeDescriptors {
    var descriptors = [Int32](repeating: 0, count: 2)
    guard Darwin.pipe(&descriptors) == 0 else {
      throw JourneyTestProcessTransportError.launchFailed(errno)
    }
    return (descriptors[0], descriptors[1])
  }
  private func spawn(
    arguments: [String], environment: [String: String], input: Int32,
    stdoutPipe: PipeDescriptors, stderrPipe: PipeDescriptors
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    let actionsCode = posix_spawn_file_actions_init(&actions)
    guard actionsCode == 0 else { throw JourneyTestProcessTransportError.launchFailed(actionsCode) }
    let attributesCode = posix_spawnattr_init(&attributes)
    guard attributesCode == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      throw JourneyTestProcessTransportError.launchFailed(attributesCode)
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    func requireSuccess(_ code: Int32) throws {
      guard code == 0 else { throw JourneyTestProcessTransportError.launchFailed(code) }
    }
    try requireSuccess(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
    try requireSuccess(
      posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO))
    try requireSuccess(
      posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO))
    if input != STDIN_FILENO {
      try requireSuccess(posix_spawn_file_actions_addclose(&actions, input))
    }
    for fd in [stdoutPipe.read, stderrPipe.read, stdoutPipe.write, stderrPipe.write] {
      try requireSuccess(posix_spawn_file_actions_addclose(&actions, fd))
    }
    try requireSuccess(
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
    try requireSuccess(posix_spawnattr_setpgroup(&attributes, 0))
    var pid: pid_t = 0
    let code = try cStrings([executableURL.path] + arguments) { argv in
      try cStrings(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }) { env in
        posix_spawn(&pid, executableURL.path, &actions, &attributes, argv, env)
      }
    }
    guard code == 0 else { throw JourneyTestProcessTransportError.launchFailed(code) }
    return pid
  }
  private func cStrings<R>(
    _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
  ) throws -> R {
    var pointers = strings.map { strdup($0) }
    guard !pointers.contains(where: { $0 == nil }) else {
      pointers.forEach { free($0) }
      throw JourneyTestProcessTransportError.launchFailed(ENOMEM)
    }
    defer { pointers.forEach { free($0) } }
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
  }
  private func startReader(
    _ descriptor: Int32, _ collector: Collector, _ group: DispatchGroup,
    _ processGroup: pid_t
  ) {
    group.enter()
    DispatchQueue.global().async {
      defer {
        group.leave()
        close(descriptor)
      }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count <= 0 {
          if count < 0 { collector.fail() }
          return
        }
        if !collector.append(count) {
          _ = kill(-processGroup, SIGTERM)
          return
        }
      }
    }
  }
  private func stop(_ processGroup: pid_t) {
    _ = kill(-processGroup, SIGTERM)
    waitForExit(processGroup, interval: 0.3)
    if exists(processGroup) {
      _ = kill(-processGroup, SIGKILL)
      waitForExit(processGroup, interval: 0.3)
    }
  }
  private func exists(_ processGroup: pid_t) -> Bool {
    kill(-processGroup, 0) == 0 || errno == EPERM
  }
  private func waitForExit(_ processGroup: pid_t, interval: TimeInterval) {
    let deadline = ProcessInfo.processInfo.systemUptime + interval
    while exists(processGroup) && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
  }
  private static func exitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }
}
final class JourneyTestCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var isCancelled = false
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isCancelled
  }
  func cancel() {
    lock.lock()
    isCancelled = true
    lock.unlock()
  }
}
private final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var byteCount = 0
  private var exceeded = false
  private var readFailed = false
  init(limit: Int) { self.limit = limit }
  func append(_ count: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    byteCount += count
    exceeded = byteCount > limit
    return !exceeded
  }
  func fail() {
    lock.lock()
    readFailed = true
    lock.unlock()
  }
  func snapshot() -> (exceeded: Bool, readFailed: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (exceeded, readFailed)
  }
}
