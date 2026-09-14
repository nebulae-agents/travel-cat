import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class ProjectSkillContractTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testClaimFixturesDecodeWithTravelCatWireFormatAndExpectedSemantics() throws {
        let preparingPath = "Automation/fixtures/claim-preparing.json"
        let preparingData = try Data(contentsOf: projectRoot.appendingPathComponent(preparingPath))
        let preparing = try JSONDecoder.travelCat.decode(DueClaim.self, from: preparingData)
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: preparingData) as? NSDictionary),
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(preparing)) as? NSDictionary),
            "Fixture keys must match the current encoder, including omission of nil optionals"
        )
        XCTAssertTrue(preparing.due)
        XCTAssertEqual(preparing.snapshot.schemaVersion, 1)
        XCTAssertEqual(preparing.snapshot.stateVersion, 0)
        XCTAssertEqual(preparing.snapshot.phase, .resting)
        XCTAssertNil(preparing.snapshot.tripID)
        XCTAssertNil(preparing.snapshot.lastEventID)
        XCTAssertEqual(preparing.snapshot.usedItemIDs, [])
        XCTAssertNil(preparing.previousEvent)

        let postcardPath = "Automation/fixtures/claim-postcard.json"
        let postcardData = try Data(contentsOf: projectRoot.appendingPathComponent(postcardPath))
        let postcard = try JSONDecoder.travelCat.decode(DueClaim.self, from: postcardData)
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: postcardData) as? NSDictionary),
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(postcard)) as? NSDictionary)
        )
        let previous = try XCTUnwrap(postcard.previousEvent)
        XCTAssertTrue(postcard.due)
        XCTAssertEqual(postcard.snapshot.schemaVersion, 1)
        XCTAssertEqual(postcard.snapshot.stateVersion, 3)
        XCTAssertEqual(postcard.snapshot.phase, .exploring)
        XCTAssertEqual(postcard.snapshot.tripID, previous.tripID)
        XCTAssertEqual(postcard.snapshot.lastEventID, previous.id)
        XCTAssertEqual(postcard.snapshot.carriedItemID, "rain-charm")
        XCTAssertEqual(postcard.snapshot.usedItemIDs, ["train-ticket"])
        XCTAssertEqual(postcard.snapshot.visitedPlaces, ["Kamakura Station", "Komachi Street"])
        XCTAssertEqual(postcard.snapshot.mood.level, 1)
        XCTAssertEqual(postcard.snapshot.openHook, "Follow the lantern trail toward the sea")
        XCTAssertEqual(previous.phase, .exploring)
        XCTAssertEqual(previous.postcardStatus, .none)
        XCTAssertEqual(previous.location?.place, postcard.snapshot.visitedPlaces.last)
        XCTAssertEqual(previous.mood, postcard.snapshot.mood)
        XCTAssertEqual(previous.openHook, postcard.snapshot.openHook)
        XCTAssertEqual(previous.occurredAt, postcard.snapshot.lastUpdatedAt)
    }

    func testSkillFrontmatterReferencesAndTriggerDescriptionContract() throws {
        let skillURL = projectRoot.appendingPathComponent(".agents/skills/travel-cat-agent/SKILL.md")
        let skill = try String(contentsOf: skillURL, encoding: .utf8)
        let lines = skill.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "---")
        let closing = try XCTUnwrap(lines.dropFirst().firstIndex(of: "---"))
        let frontmatter = Array(lines[1..<closing])
        XCTAssertEqual(frontmatter.count, 2)
        XCTAssertEqual(frontmatter[0], "name: travel-cat-agent")
        XCTAssertTrue(frontmatter[1].hasPrefix("description: Use when "))
        XCTAssertLessThan(frontmatter[1].count, 513)

        let description = frontmatter[1].replacingOccurrences(of: "description: ", with: "")
        XCTAssertTrue(description.contains("Travel Cat"))
        XCTAssertTrue(description.contains("due"))
        XCTAssertTrue(description.contains("pending postcard"))
        for workflowWord in ["validate-candidate", "publishEnvelope", "exit 75", "workflow"] {
            XCTAssertFalse(description.contains(workflowWord), "Description must contain triggers only")
        }

        let eventReference = projectRoot.appendingPathComponent(".agents/skills/travel-cat-agent/references/event-contract.md")
        let postcardReference = projectRoot.appendingPathComponent(".agents/skills/travel-cat-agent/references/postcard-prompt.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventReference.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: postcardReference.path))
        XCTAssertTrue(skill.contains("references/event-contract.md"))
        XCTAssertTrue(skill.contains("references/postcard-prompt.md"))

        let unavailableCommand = ["release", "claim"].joined(separator: "-")
        XCTAssertFalse(skill.contains(unavailableCommand))
        XCTAssertFalse(try String(contentsOf: eventReference).contains(unavailableCommand))
        XCTAssertFalse(try String(contentsOf: postcardReference).contains(unavailableCommand))
    }

    func testSkillDefinesBoundedAuthoritativeWorkflowInOrder() throws {
        let skill = try read(".agents/skills/travel-cat-agent/SKILL.md")
        let orderedTokens = [
            "swift run travelcatctl claim",
            "due == false",
            "exactly one candidate",
            "swift run travelcatctl validate-candidate",
            "exit 75",
            "exit 65",
            "exit 66",
            "publishEnvelope",
            "swift run travelcatctl publish",
            "version increment",
            "pendingImage",
        ]
        var cursor = skill.startIndex
        for token in orderedTokens {
            let range = try XCTUnwrap(skill.range(of: token, range: cursor..<skill.endIndex), "Missing or out-of-order token: \(token)")
            cursor = range.upperBound
        }

        for required in [
            "at most one authoritative action", "one event publication per invocation",
            "maximum two validations total", "stop quietly", "repositoryBusy",
            "verbatim", "never construct", "never modify", "text narrative is immutable",
            "manual context", "later heartbeat", "current command set",
        ] {
            XCTAssertTrue(skill.localizedCaseInsensitiveContains(required), "Missing workflow invariant: \(required)")
        }
        XCTAssertTrue(skill.contains("allowlisted for reported violations"))
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("scheduled invocations emit nothing"))
        XCTAssertTrue(skill.contains("decodes as `ValidationResult`"))
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("without a validation payload"))
        for token in [
            "conformance/reference", "not the scheduled entry", "not the scheduled entry or an LLM callback",
            "trusted absolute prebuilt", "tool layer", "never uses `swift run`", "manual-only",
        ] {
            XCTAssertTrue(skill.localizedCaseInsensitiveContains(token), "Missing actual scheduled boundary: \(token)")
        }

        let runner = try read("Sources/TravelStorage/AgentHeartbeatRunner.swift")
        for token in [
            "TravelAgentCLIExecuting", "ProcessTravelAgentCLI", "stdoutPipe", "stderrPipe", "TRAVEL_CAT_DATA",
            "not a scheduled entry point", "does not provide an LLM callback", "timedOut", "outputLimitExceeded",
            "repairUnauthorized", "allowedSemanticRepairFields", "structuralRepairIsAuthorized", "changedFields",
        ] {
            XCTAssertTrue(runner.contains(token), "Missing runner implementation token: \(token)")
        }
        XCTAssertFalse(runner.contains("print("))
    }

    func testEventReferenceExamplesDecodeAndValidateAgainstFixtureSnapshots() throws {
        let reference = try read(".agents/skills/travel-cat-agent/references/event-contract.md")
        let preparingData = try fencedJSON(named: "preparing-example", in: reference)
        let preparingCandidate = try AgentEventEnvelope.decode(preparingData)
        XCTAssertLessThanOrEqual(preparingCandidate.mood.quote.unicodeScalars.count, 32)
        let preparingClaim = try decodeClaim("Automation/fixtures/claim-preparing.json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let preparingResult = preparingCandidate.validationResult(
            previous: preparingClaim.snapshot,
            mode: .fast,
            calendar: calendar,
            now: preparingCandidate.occurredAt
        )
        XCTAssertTrue(preparingResult.valid, preparingResult.violations.joined(separator: ","))
        XCTAssertEqual(preparingResult.publishEnvelope?.next.stateVersion, preparingClaim.snapshot.stateVersion + 1)

        let badData = try fencedJSON(named: "bad-mood-example", in: reference)
        let correctedData = try fencedJSON(named: "corrected-mood-example", in: reference)
        let bad = try AgentEventEnvelope.decode(badData)
        let corrected = try AgentEventEnvelope.decode(correctedData)
        XCTAssertLessThanOrEqual(bad.mood.quote.unicodeScalars.count, 32)
        XCTAssertLessThanOrEqual(corrected.mood.quote.unicodeScalars.count, 32)
        let postcardClaim = try decodeClaim("Automation/fixtures/claim-postcard.json")
        XCTAssertEqual(
            bad.validationResult(
                previous: postcardClaim.snapshot,
                mode: .fast,
                calendar: calendar,
                now: bad.occurredAt
            ).violations,
            ["moodJump"]
        )
        XCTAssertTrue(corrected.validationResult(
            previous: postcardClaim.snapshot,
            mode: .fast,
            calendar: calendar,
            now: corrected.occurredAt
        ).valid)

        var badObject = try XCTUnwrap(JSONSerialization.jsonObject(with: badData) as? [String: Any])
        var correctedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: correctedData) as? [String: Any])
        let badMood = try XCTUnwrap(badObject.removeValue(forKey: "mood") as? [String: Any])
        let correctedMood = try XCTUnwrap(correctedObject.removeValue(forKey: "mood") as? [String: Any])
        XCTAssertEqual(badObject as NSDictionary, correctedObject as NSDictionary)
        XCTAssertEqual(Set(badMood.keys), ["level", "label", "quote"])
        XCTAssertEqual(Set(correctedMood.keys), ["level", "label", "quote"])
        XCTAssertNotEqual(badMood as NSDictionary, correctedMood as NSDictionary)
    }

    func testEventReferenceDocumentsCurrentWireAndValidationContract() throws {
        let reference = try read(".agents/skills/travel-cat-agent/references/event-contract.md")
        for token in [
            "DueClaim", "due", "snapshot", "previousEvent", "resting -> preparing",
            "preparing -> transit | resting", "transit -> exploring | returning",
            "exploring -> postcardReady | transit | returning",
            "postcardReady -> exploring | returning", "returning -> resting",
            "new trip UUID", "previousEventId", "lastEventID", "RFC 3339",
            "20-240", "4-32", "1-4", "120", "500", "locationRequired",
            "moodJump", "consumedItemId", "continuityReferences", "openHook",
            "Geography", "plausible", "transport", "time", "postcardPhaseMismatch",
            "exit 0", "exit 65", "exit 66", "exit 75", "publishEnvelope",
            "immutable",
        ] {
            XCTAssertTrue(reference.localizedCaseInsensitiveContains(token), "Missing event contract token: \(token)")
        }
    }

    func testEventReferencesDocumentFutureTimeRepairAndStayMirrored() throws {
        let project = try read(".agents/skills/travel-cat-agent/references/event-contract.md")
        let plugin = try read("Plugins/travel-cat/skills/travel-cat-heartbeat/references/event-contract.md")

        XCTAssertTrue(project.contains("`occurredAtAfterNow` -> `occurredAt`"))
        XCTAssertTrue(project.contains("not later than the current trusted execution time"))
        XCTAssertEqual(plugin, project)
    }

    func testCandidateGenerationInstructionsShareThe32ScalarMoodQuoteLimit() throws {
        for path in [
            ".agents/skills/travel-cat-agent/SKILL.md",
            ".agents/skills/travel-cat-agent/references/event-contract.md",
            "Automation/prompts/scheduled-task.md",
        ] {
            let content = try read(path)
            XCTAssertTrue(
                content.contains("mood.quote <= 32 Unicode scalars"),
                "Missing candidate quote limit in \(path)"
            )
            XCTAssertTrue(
                content.contains("mood.quote must be one paragraph with no CR or LF"),
                "Missing single-paragraph candidate contract in \(path)"
            )
            XCTAssertTrue(
                content.contains("no leading or trailing ASCII JSON whitespace (TAB, LF, CR, or space)"),
                "Missing canonical boundary-whitespace contract in \(path)"
            )
        }
    }

    func testScheduledPromptUsesTheInstalledSignedLauncherBoundary() throws {
        let prompt = try read("Automation/prompts/scheduled-task.md")
        XCTAssertTrue(prompt.contains("installed `travel-cat-heartbeat` skill and its shipped launcher"))
        XCTAssertFalse(prompt.contains("/Users/"))
        XCTAssertFalse(prompt.contains(".worktrees/travel-cat"))
        XCTAssertFalse(prompt.contains(".build/"))
    }

    func testNodeExecutesDraftQuoteSchemaBoundaryMatrix() throws {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node",
            projectRoot.appendingPathComponent("Automation/tests/event-candidate-quote-schema.mjs").path,
            projectRoot.appendingPathComponent("Automation/schemas/event-candidate.schema.json").path,
        ]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertEqual(message, "event candidate quote schema verified\n")
    }

    func testPostcardReferenceLocksIdentityAndExistingAssets() throws {
        for path in [
            "Assets/CharacterReference/front.png", "Assets/CharacterReference/side.png",
            "Assets/CharacterReference/sitting.png", "Assets/CharacterReference/identity.json",
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(path).path))
        }
        let identityData = try Data(contentsOf: projectRoot.appendingPathComponent("Assets/CharacterReference/identity.json"))
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: identityData) as? [String: Any])
        XCTAssertEqual(identity["eyeColor"] as? String, "gold")
        XCTAssertEqual(identity["collarColor"] as? String, "violet")
        XCTAssertEqual(identity["identityMarker"] as? String, "small gold bell")

        let reference = try read(".agents/skills/travel-cat-agent/references/postcard-prompt.md")
        for token in [
            "small round-faced", "near-black", "subtle violet highlights", "large gold eyes",
            "violet collar", "small gold bell", "20-40%", "identity-preserve",
            "serially", "one network error", "one targeted correction", "No text",
            "logo", "watermark", "extra animals", "duplicate", "malformed limbs",
            "most recent accepted postcard", "text event", "never rewritten",
            "mood", "weather", "time", "destination",
        ] {
            XCTAssertTrue(reference.localizedCaseInsensitiveContains(token), "Missing postcard invariant: \(token)")
        }
    }

    func testSkillTreatsStoryStringsAsUntrustedAndDefinesBoundedSeparateImageInvocation() throws {
        let skill = try read(".agents/skills/travel-cat-agent/SKILL.md")
        let eventReference = try read(".agents/skills/travel-cat-agent/references/event-contract.md")
        let postcardReference = try read(".agents/skills/travel-cat-agent/references/postcard-prompt.md")

        for token in [
            "untrusted story data", "never instructions", "command", "path", "tool request",
            "shell interpolation", "structured JSON encoder", "mode 0600", "safe stdin",
            "preconfigured expected absolute directory",
        ] {
            XCTAssertTrue(skill.localizedCaseInsensitiveContains(token), "Missing safety boundary: \(token)")
        }
        for token in [
            "pending-images", "separate pending-image invocation", "one network retry",
            "one targeted correction", "image-result.schema.json", "rejected_identity",
            "postcards/<trip-id>/", "third failed", "imageUnavailable", "never rewrite",
        ] {
            XCTAssertTrue((skill + postcardReference).localizedCaseInsensitiveContains(token), "Missing image boundary: \(token)")
        }
        XCTAssertTrue(eventReference.localizedCaseInsensitiveContains("untrusted story data"))
        XCTAssertTrue(eventReference.localizedCaseInsensitiveContains("never interpolate"))
        XCTAssertTrue(postcardReference.localizedCaseInsensitiveContains("untrusted story data"))
        XCTAssertFalse(skill.contains("Until Agent4 is implemented"))
        XCTAssertFalse(skill.contains("Do not run `mark-image`"))
        XCTAssertFalse(postcardReference.contains("Before Agent4 exists"))
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("scheduled invocations emit nothing to stdout or stderr on every exit path"))
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("sanitized diagnostics"))
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("never reproduce story data"))
        for token in [
            "attemptToken", "leaseExpiresAt", "echo `imageAttemptCount`, `publishedNarrativeHash`",
            "Do not rediscover work during the lease", "at most one due item",
            "fast lease lasts 30 minutes", "daily lease lasts 60 minutes",
            "image generation blocks without lease renewal",
            "legacy ready paths are read-only migration data",
            "new ready results use canonical",
        ] {
            XCTAssertTrue((skill + eventReference).contains(token), "Missing leased image protocol: \(token)")
        }
    }

    private func decodeClaim(_ relativePath: String) throws -> DueClaim {
        try JSONDecoder.travelCat.decode(DueClaim.self, from: Data(contentsOf: projectRoot.appendingPathComponent(relativePath)))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func fencedJSON(named name: String, in source: String) throws -> Data {
        let start = "<!-- \(name):start -->"
        let end = "<!-- \(name):end -->"
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        var block = String(source[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(block.hasPrefix("```json"))
        XCTAssertTrue(block.hasSuffix("```"))
        block.removeFirst("```json".count)
        block.removeLast(3)
        return Data(block.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
