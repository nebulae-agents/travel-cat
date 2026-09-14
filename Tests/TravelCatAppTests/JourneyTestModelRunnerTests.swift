import Foundation
import XCTest

@testable import TravelCatApp
@testable import TravelStorage

final class JourneyTestModelRunnerTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var session: JourneyTestSession!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JourneyTestModelRunnerTests-\(UUID().uuidString)", isDirectory: true)
    let parent = temporaryDirectory.appendingPathComponent("JourneyTests", isDirectory: true)
    let production = temporaryDirectory.appendingPathComponent("Production", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
    session = try JourneyTestSession.create(parent: parent, productionRoot: production)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
  }

  func testGeneratesValidatedJSONInAnExclusiveRequestDirectory() async throws {
    let executable = try makeExecutable(
      named: "writer",
      body: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then output="$2"; shift 2; continue; fi
          shift
        done
        cat >/dev/null
        printf '{"place":"Kyoto"}' > "$output"
        """)
    let runner = try JourneyTestModelRunner(
      executableURL: executable, environment: ["PATH": "/usr/bin:/bin"])
    let schema = Data("{\"type\":\"object\"}".utf8)

    let result = try await runner.generateJSON(
      prompt: "literal $HOME ; no interpolation",
      schema: schema,
      session: session,
      referenceImage: nil
    )

    XCTAssertEqual(result, Data("{\"place\":\"Kyoto\"}".utf8))
    let requests = try FileManager.default.contentsOfDirectory(
      at: session.root, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("model-request-") }
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(try Data(contentsOf: requests[0].appendingPathComponent("schema.json")), schema)
  }

  func testRejectsNonzeroExitAndSymlinkedFinalOutput() async throws {
    let nonzero = try makeExecutable(named: "nonzero", body: "#!/bin/sh\nexit 17\n")
    let runner = try JourneyTestModelRunner(
      executableURL: nonzero, environment: ["PATH": "/usr/bin:/bin"])
    await XCTAssertThrowsErrorAsync(
      try await runner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: nil)
    ) { error in
      XCTAssertEqual(error as? JourneyTestProcessTransportError, .launchFailed(17))
    }

    let symlink = try makeExecutable(
      named: "symlink",
      body: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do if [ "$1" = "--output-last-message" ]; then output="$2"; shift 2; continue; fi; shift; done
        ln -s /etc/hosts "$output"
        """)
    let symlinkRunner = try JourneyTestModelRunner(
      executableURL: symlink, environment: ["PATH": "/usr/bin:/bin"])
    await XCTAssertThrowsErrorAsync(
      try await symlinkRunner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: nil)
    ) { error in
      XCTAssertEqual(error as? JourneyTestModelRunnerError, .resultSymlink)
    }
  }

  func testReportsSignalTerminatedProcessWithConventionalExitStatus() async throws {
    let terminated = try makeExecutable(
      named: "terminated",
      body: "#!/bin/sh\nkill -KILL $$\n"
    )
    let runner = try JourneyTestModelRunner(
      executableURL: terminated,
      environment: ["PATH": "/usr/bin:/bin"]
    )

    await XCTAssertThrowsErrorAsync(
      try await runner.generateJSON(
        prompt: "x",
        schema: Data("{}".utf8),
        session: session,
        referenceImage: nil
      )
    ) { error in
      XCTAssertEqual(
        error as? JourneyTestProcessTransportError,
        .launchFailed(137),
        "unexpected error: \(error)"
      )
    }
  }

  func testBoundsOutputAndTerminatesTimedOutProcess() async throws {
    let overflowing = try makeExecutable(
      named: "overflow", body: "#!/bin/sh\nexec /usr/bin/yes output\n")
    let overflowRunner = try JourneyTestModelRunner(
      executableURL: overflowing, environment: ["PATH": "/usr/bin:/bin"], timeout: 5,
      maxOutputBytes: 128)
    await XCTAssertThrowsErrorAsync(
      try await overflowRunner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: nil)
    ) { error in
      XCTAssertEqual(error as? JourneyTestProcessTransportError, .outputLimitExceeded)
    }

    let hanging = try makeExecutable(named: "hang", body: "#!/bin/sh\nexec /bin/sleep 5\n")
    let timeoutRunner = try JourneyTestModelRunner(
      executableURL: hanging, environment: ["PATH": "/usr/bin:/bin"], timeout: 0.1)
    await XCTAssertThrowsErrorAsync(
      try await timeoutRunner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: nil)
    ) { error in
      XCTAssertEqual(error as? JourneyTestProcessTransportError, .timedOut)
    }
  }

  func testCancellationTerminatesOnlyItsOwnedProcessGroup() async throws {
    let hanging = try makeExecutable(
      named: "cancel",
      body: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do if [ "$1" = "--output-last-message" ]; then output="$2"; shift 2; continue; fi; shift; done
        dir=$(/usr/bin/dirname "$output")
        touch "$dir/started"
        exec /bin/sleep 5
        """)
    let runner = try JourneyTestModelRunner(
      executableURL: hanging, environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
    let taskSession = try XCTUnwrap(session)
    let task = Task {
      try await runner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: taskSession, referenceImage: nil)
    }
    try await waitForRequestMarker("started")
    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value) { error in
      XCTAssertEqual(error as? JourneyTestProcessTransportError, .cancelled)
    }
  }

  func testPreCancelledTaskDoesNotCreateRequestFiles() async throws {
    let executable = try makeExecutable(named: "never-runs", body: "#!/bin/sh\nexit 0\n")
    let runner = try JourneyTestModelRunner(
      executableURL: executable, environment: ["PATH": "/usr/bin:/bin"])
    let taskSession = try XCTUnwrap(session)
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return try await runner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: taskSession, referenceImage: nil)
    }
    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value) { error in
      XCTAssertTrue(error is CancellationError)
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: session.root.path)
    XCTAssertFalse(names.contains { $0.hasPrefix("model-request-") })
  }

  func testPassesLiteralPromptAndRestrictedCodexInvocationEnvironment() async throws {
    let recorder = try makeExecutable(
      named: "recorder",
      body: """
        #!/bin/sh
        original_arguments="$*"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then output="$2"; shift 2; continue; fi
          shift
        done
        dir=$(dirname "$output")
        printf '%s\\n' "$original_arguments" > "$dir/argv.txt"
        env > "$dir/environment.txt"
        cat > "$dir/stdin.txt"
        printf '{}' > "$output"
        """)
    let runner = try JourneyTestModelRunner(
      executableURL: recorder,
      environment: [
        "HOME": "/safe/home", "PATH": "/usr/bin:/bin", "LANG": "C", "CODEX_THREAD_ID": "secret",
        "TRAVEL_CAT_DATA": "/production",
      ])
    let prompt = "literal $HOME ; $(whoami)"
    _ = try await runner.generateJSON(
      prompt: prompt, schema: Data("{}".utf8), session: session, referenceImage: nil)
    let request = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: session.root, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("model-request-") })
    let environment = try String(
      contentsOf: request.appendingPathComponent("environment.txt"), encoding: .utf8)
    let arguments = try String(
      contentsOf: request.appendingPathComponent("argv.txt"), encoding: .utf8)
    let stdin = try String(contentsOf: request.appendingPathComponent("stdin.txt"), encoding: .utf8)
    XCTAssertEqual(stdin, prompt)
    XCTAssertTrue(arguments.contains("exec --ignore-user-config --ephemeral --skip-git-repo-check"))
    XCTAssertTrue(arguments.contains("--sandbox read-only"))
    XCTAssertTrue(arguments.contains("--disable apps --disable plugins --disable hooks"))
    XCTAssertTrue(arguments.contains("--disable browser_use --disable computer_use"))
    XCTAssertTrue(arguments.contains("--json -C \(session.root.path)"))
    XCTAssertTrue(environment.contains("HOME=/safe/home"))
    XCTAssertFalse(environment.contains("CODEX_THREAD_ID"))
    XCTAssertFalse(environment.contains("TRAVEL_CAT_DATA"))
  }

  func testRejectsSchemaThatIsNotAJSONObject() async throws {
    let executable = try makeExecutable(named: "never-schema", body: "#!/bin/sh\nexit 0\n")
    let runner = try JourneyTestModelRunner(
      executableURL: executable,
      environment: ["PATH": "/usr/bin:/bin"]
    )

    for schema in ["not-json", "42", "[]", "null"] {
      await XCTAssertThrowsErrorAsync(
        try await runner.generateJSON(
          prompt: "x",
          schema: Data(schema.utf8),
          session: session,
          referenceImage: nil
        )
      ) { error in
        XCTAssertEqual(error as? JourneyTestModelRunnerError, .invalidSchema)
      }
    }

    let names = try FileManager.default.contentsOfDirectory(atPath: session.root.path)
    XCTAssertFalse(names.contains { $0.hasPrefix("model-request-") })
  }

  func testRejectsMissingEmptyMalformedAndOversizeFinalResult() async throws {
    for (name, command, limit, expected) in [
      ("missing", ":", 128, JourneyTestModelRunnerError.invalidResult),
      ("empty", "printf '' > \"$output\"", 128, .invalidResult),
      ("malformed", "printf 'not-json' > \"$output\"", 128, .invalidResult),
      ("scalar", "printf '42' > \"$output\"", 128, .invalidResult),
      (
        "oversize", "dd if=/dev/zero of=\"$output\" bs=1 count=129 2>/dev/null", 128,
        .resultTooLarge
      ),
    ] {
      let executable = try makeExecutable(
        named: name,
        body: """
          #!/bin/sh
          while [ "$#" -gt 0 ]; do if [ "$1" = "--output-last-message" ]; then output="$2"; shift 2; continue; fi; shift; done
          \(command)
          """)
      let runner = try JourneyTestModelRunner(
        executableURL: executable, environment: ["PATH": "/usr/bin:/bin"], maxOutputBytes: limit)
      await XCTAssertThrowsErrorAsync(
        try await runner.generateJSON(
          prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: nil)
      ) { error in
        XCTAssertEqual(error as? JourneyTestModelRunnerError, expected)
      }
    }
  }

  func testReferenceRequiresDecodedPNGOrWebP() async throws {
    let writer = try makeExecutable(
      named: "reference-writer",
      body: """
        #!/bin/sh
        original_arguments="$*"
        while [ "$#" -gt 0 ]; do if [ "$1" = "--output-last-message" ]; then output="$2"; shift 2; continue; fi; shift; done
        dir=$(dirname "$output")
        printf '%s\n' "$original_arguments" > "$dir/argv.txt"
        printf '{}' > "$output"
        """)
    let runner = try JourneyTestModelRunner(
      executableURL: writer, environment: ["PATH": "/usr/bin:/bin"])
    let fake = temporaryDirectory.appendingPathComponent("fake.png")
    try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: fake)
    await XCTAssertThrowsErrorAsync(
      try await runner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: fake)
    ) { error in
      XCTAssertEqual(error as? JourneyTestModelRunnerError, .invalidReference)
    }
    let missing = temporaryDirectory.appendingPathComponent("missing.png")
    await XCTAssertThrowsErrorAsync(
      try await runner.generateJSON(
        prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: missing)
    ) { error in
      XCTAssertEqual(error as? JourneyTestModelRunnerError, .invalidReference)
    }
    let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Assets/CharacterReference/side.png")
    let accepted = try await runner.generateJSON(
      prompt: "x", schema: Data("{}".utf8), session: session, referenceImage: bundled)
    XCTAssertEqual(accepted, Data("{}".utf8))
    let request = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: session.root, includingPropertiesForKeys: nil)
        .first {
          FileManager.default.fileExists(atPath: $0.appendingPathComponent("reference.png").path)
        })
    let copiedReference = request.appendingPathComponent("reference.png")
    XCTAssertEqual(try Data(contentsOf: copiedReference), try Data(contentsOf: bundled))
    let arguments = try String(
      contentsOf: request.appendingPathComponent("argv.txt"), encoding: .utf8)
    XCTAssertTrue(arguments.contains(" -i "), arguments)
    XCTAssertTrue(arguments.contains("/reference.png"), arguments)
  }

  private func makeExecutable(named: String, body: String) throws -> URL {
    let url = temporaryDirectory.appendingPathComponent(named)
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private func waitForRequestMarker(_ marker: String) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let request = try? FileManager.default.contentsOfDirectory(
        at: session.root, includingPropertiesForKeys: nil
      ).first(where: { $0.lastPathComponent.hasPrefix("model-request-") }),
        FileManager.default.fileExists(atPath: request.appendingPathComponent(marker).path)
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for \(marker)")
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T, _ handler: (Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error")
  } catch { handler(error) }
}
