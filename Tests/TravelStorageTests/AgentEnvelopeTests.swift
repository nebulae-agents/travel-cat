import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class AgentEnvelopeTests: XCTestCase {
    private let eventID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let tripID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
    private let occurredAt = Date(timeIntervalSince1970: 1_786_449_600)

    func testValidCandidateProjectsPublishEnvelopeWithoutMutatingRepository() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: FixedClock(now: occurredAt))
        let before = try repository.loadSnapshot()
        let candidate = try AgentEventEnvelope.decode(candidateData())

        let result = candidate.validationResult(previous: before, mode: .fast, calendar: utcCalendar())

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.violations, [])
        XCTAssertEqual(result.stateVersion, 0)
        let publish = try XCTUnwrap(result.publishEnvelope)
        XCTAssertEqual(publish.event.id, eventID)
        XCTAssertEqual(publish.event.tripID, tripID)
        XCTAssertEqual(publish.event.postcardStatus, .none)
        XCTAssertNil(publish.event.postcardRelativePath)
        XCTAssertEqual(publish.next.stateVersion, 1)
        XCTAssertEqual(publish.next.tripID, tripID)
        XCTAssertEqual(publish.next.lastEventID, eventID)
        XCTAssertEqual(publish.next.phase, .preparing)
        XCTAssertEqual(publish.next.nextActionAt, occurredAt.addingTimeInterval(120))
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertEqual(try repository.events(), [])
    }

    func testMoodJumpHasStableDomainViolation() throws {
        let candidate = try AgentEventEnvelope.decode(candidateData(moodLevel: 2))
        let previous = TripSnapshot.empty(now: occurredAt)

        let result = candidate.validationResult(previous: previous, mode: .fast, calendar: utcCalendar())

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.violations, ["moodJump"])
        XCTAssertEqual(result.stateVersion, 0)
        XCTAssertNil(result.publishEnvelope)
    }

    func testFutureCandidateHasStableViolationAndNoPublishEnvelope() throws {
        let candidate = try AgentEventEnvelope.decode(candidateData())
        let previous = TripSnapshot.empty(now: occurredAt)

        let result = candidate.validationResult(
            previous: previous,
            mode: .fast,
            calendar: utcCalendar(),
            now: occurredAt.addingTimeInterval(-1)
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.violations, ["occurredAtAfterNow"])
        XCTAssertNil(result.publishEnvelope)
    }

    func testStrictDecoderRejectsUnknownMissingMalformedAndWhitespaceFields() throws {
        assertStructural(candidateData(extraTopLevel: "\"surprise\":true,"), "unknownKey:surprise")
        assertStructural(candidateData(extraMood: ",\"surprise\":true"), "unknownKey:mood.surprise")
        assertStructural(candidateData(summary: nil), "missing:summary")
        assertStructural(candidateData(eventID: "not-a-uuid"), "invalid:eventId")
        assertStructural(candidateData(occurredAt: "tomorrow"), "invalid:occurredAt")
        assertStructural(candidateData(summary: " 二十个字符以上但首尾包含空白是不允许的内容 "), "untrimmed:summary")
        assertStructural(candidateData(references: ["锚点", "锚点"]), "duplicate:continuityReferences")
        assertStructural(candidateData(quote: "短"), "length:mood.quote")
        assertStructural(candidateData(summary: String(repeating: "🐈", count: 19)), "length:summary")
        XCTAssertNoThrow(try AgentEventEnvelope.decode(candidateData(summary: String(repeating: "🐈", count: 20))))
    }

    func testCandidateMoodQuoteAccepts32AndRejects33UnicodeScalarsWithStableViolation() throws {
        XCTAssertNoThrow(try AgentEventEnvelope.decode(
            candidateData(quote: String(repeating: "旅", count: 32))
        ))
        XCTAssertEqual(
            structuralViolations(candidateData(quote: String(repeating: "旅", count: 33))),
            ["length:mood.quote"]
        )
    }

    func testCandidateSchemaMatchesRuntimeMoodQuoteScalarLimit() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appendingPathComponent(
            "Automation/schemas/event-candidate.schema.json"
        ))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let mood = try XCTUnwrap(properties["mood"] as? [String: Any])
        let moodProperties = try XCTUnwrap(mood["properties"] as? [String: Any])
        let quote = try XCTUnwrap(moodProperties["quote"] as? [String: Any])

        XCTAssertEqual((quote["minLength"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((quote["maxLength"] as? NSNumber)?.intValue, 32)
        let pattern = try XCTUnwrap(quote["pattern"] as? String)
        XCTAssertEqual(
            pattern,
            "^(?![^]*[\\u000A\\u000D])(?![\\u0009\\u000A\\u000D\\u0020])(?![^]*[\\u0009\\u0020]$)"
        )
    }

    func testCandidateMoodQuoteUsesExplicitASCIIJSONBoundaryWhitespaceSet() {
        for quote in [
            "\\u0085潮声方向", "潮声方向\\u0085",
            "\\u200B潮声方向", "潮声方向\\u200B",
            "\\uFEFF潮声方向", "潮声方向\\uFEFF",
        ] {
            XCTAssertNoThrow(try AgentEventEnvelope.decode(candidateData(quote: quote)))
            XCTAssertNoThrow(try JSONDecoder.travelCat.decode(
                AgentEventEnvelope.self,
                from: candidateData(quote: quote)
            ))
        }

        for quote in ["\\t潮声方向", "潮声方向\\t", " 潮声方向", "潮声方向 "] {
            XCTAssertEqual(structuralViolations(candidateData(quote: quote)), ["untrimmed:mood.quote"])
        }
        for quote in ["\\n潮声方向", "潮声方向\\n", "\\r潮声方向", "潮声方向\\r"] {
            XCTAssertEqual(
                structuralViolations(candidateData(quote: quote)),
                ["untrimmed:mood.quote", "newline:mood.quote"]
            )
        }
    }

    func testCandidateMoodQuotePreservesLiteralAndEscapedFEFFAcrossStructuralAndDirectDecoders() throws {
        let acceptedWireValues = [
            "\u{FEFF}旅旅旅", "旅旅旅\u{FEFF}",
            "\\uFEFF旅旅旅", "旅旅旅\\uFEFF",
        ]

        for wireValue in acceptedWireValues {
            let data = candidateData(quote: wireValue)
            let structural = try AgentEventEnvelope.decode(data)
            let direct = try JSONDecoder.travelCat.decode(AgentEventEnvelope.self, from: data)

            XCTAssertEqual(structural.mood.quote.unicodeScalars.count, 4)
            XCTAssertEqual(direct.mood.quote.unicodeScalars.count, 4)
            XCTAssertEqual(structural.mood.quote, direct.mood.quote)
            XCTAssertTrue(
                structural.mood.quote.unicodeScalars.first?.value == 0xFEFF
                    || structural.mood.quote.unicodeScalars.last?.value == 0xFEFF
            )
        }

        let overlongWireValues = [
            "\u{FEFF}" + String(repeating: "旅", count: 32),
            String(repeating: "旅", count: 32) + "\u{FEFF}",
            "\\uFEFF" + String(repeating: "旅", count: 32),
            String(repeating: "旅", count: 32) + "\\uFEFF",
        ]
        for wireValue in overlongWireValues {
            let data = candidateData(quote: wireValue)
            XCTAssertEqual(structuralViolations(data), ["length:mood.quote"])
            XCTAssertThrowsError(try JSONDecoder.travelCat.decode(AgentEventEnvelope.self, from: data))
        }
    }

    func testCandidateMoodQuoteRejectsLFCRAndCRLFAndOneTwoThreeNewlinesWithStableViolation() {
        for quote in [
            "潮声\\n会替今天记住方向。",
            "潮声\\r会替今天记住方向。",
            "潮声\\r\\n会替今天记住方向。",
            "潮\\n声\\r会替今天记住方向。",
            "潮\\r\\n声\\n会替今天\\r记住方向。",
        ] {
            XCTAssertEqual(structuralViolations(candidateData(quote: quote)), ["newline:mood.quote"])
            XCTAssertThrowsError(try JSONDecoder.travelCat.decode(
                AgentEventEnvelope.self,
                from: candidateData(quote: quote)
            ))
        }
    }

    func testStrictJSONPreflightRejectsDuplicateKeysAtEveryObjectDepth() {
        let base = String(decoding: candidateData(), as: UTF8.self)
        assertStructural(
            Data(base.replacingOccurrences(of: "{\"eventId\"", with: "{\"phase\":\"preparing\",\"eventId\"", options: [], range: base.range(of: "{\"eventId\"")).utf8),
            "duplicateKey:phase"
        )
        assertStructural(
            Data(base.replacingOccurrences(of: "\"mood\":{\"level\":", with: "\"mood\":{\"level\":0,\"level\":").utf8),
            "duplicateKey:level"
        )
        assertStructural(
            Data(base.replacingOccurrences(of: "\"postcard\":{\"required\":", with: "\"postcard\":{\"required\":false,\"required\":").utf8),
            "duplicateKey:required"
        )
        assertStructural(
            Data(base.replacingOccurrences(of: "{\"eventId\"", with: "{\"ph\\u0061se\":\"preparing\",\"eventId\"", options: [], range: base.range(of: "{\"eventId\"")).utf8),
            "duplicateKey:phase"
        )
        let oversizedKey = String(repeating: "k", count: 200)
        let diagnostic = structuralViolations(Data("{\"\(oversizedKey)\":1,\"\(oversizedKey)\":2}".utf8))
        XCTAssertEqual(diagnostic.count, 1)
        XCTAssertLessThanOrEqual(diagnostic[0].unicodeScalars.count, "duplicateKey:".unicodeScalars.count + 64)
    }

    func testSameKeyInSeparateObjectsIsNotReportedAsDuplicate() {
        let base = String(decoding: candidateData(), as: UTF8.self)
        let data = Data(base.replacingOccurrences(
            of: "\"mood\":{\"level\":",
            with: "\"mood\":{\"phase\":\"nested\",\"level\":"
        ).utf8)

        XCTAssertEqual(structuralViolations(data), ["unknownKey:mood.phase"])
    }

    func testStrictRFC3339RejectsNormalizedAndMalformedDates() throws {
        for invalid in [
            "2026-02-30T12:00:00Z",
            "2025-02-29T12:00:00Z",
            "2026-08-11T24:00:00Z",
            "2026-08-11T12:00:60Z",
            "2026-08-11T12:00:00+24:00",
            "2026-08-11T12:00:00+08:60",
            "2026-08-11T12:00:00.Z",
            "2026-08-11T12:00:00Zjunk",
        ] {
            assertStructural(candidateData(occurredAt: invalid), "invalid:occurredAt")
        }

        XCTAssertNoThrow(try AgentEventEnvelope.decode(candidateData(occurredAt: "2028-02-29T12:00:00Z")))
        let offset = try AgentEventEnvelope.decode(candidateData(occurredAt: "2028-02-29T20:00:00+08:00"))
        let fractional = try AgentEventEnvelope.decode(candidateData(occurredAt: "2028-02-29T12:00:00.125Z"))
        XCTAssertEqual(offset.occurredAt, Date(timeIntervalSince1970: 1_835_438_400))
        XCTAssertEqual(fractional.occurredAt.timeIntervalSince1970, 1_835_438_400.125, accuracy: 0.000_001)
        XCTAssertThrowsError(try JSONDecoder.travelCat.decode(
            AgentEventEnvelope.self,
            from: candidateData(occurredAt: "2026-02-30T12:00:00Z")
        ))
    }

    func testStrictRFC3339AcceptsLowercaseSeparatorsWithExactProjection() throws {
        let lowercaseZ = try AgentEventEnvelope.decode(candidateData(occurredAt: "2028-02-29t12:00:00.125z"))
        let lowercaseOffset = try AgentEventEnvelope.decode(candidateData(occurredAt: "2028-02-29t20:00:00+08:00"))

        XCTAssertEqual(lowercaseZ.occurredAt.timeIntervalSince1970, 1_835_438_400.125, accuracy: 0.000_001)
        XCTAssertEqual(lowercaseOffset.occurredAt, Date(timeIntervalSince1970: 1_835_438_400))
    }

    func testTimestampSchemaPatternMatchesRuntimeNonLeapSecondSubset() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schemaData = try Data(contentsOf: projectRoot.appendingPathComponent("Automation/schemas/event-candidate.schema.json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let occurredAt = try XCTUnwrap(properties["occurredAt"] as? [String: Any])
        let pattern = try XCTUnwrap(occurredAt["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)

        for accepted in [
            "0001-01-01T00:00:00Z",
            "2028-02-29T12:00:00Z",
            "2028-02-29t12:00:00.125z",
            "2028-02-29t20:00:00+08:00",
        ] {
            XCTAssertNotNil(regex.firstMatch(in: accepted, range: NSRange(accepted.startIndex..., in: accepted)))
        }
        for rejected in ["0000-01-01T00:00:00Z", "2028-02-29T12:00:60Z", "2028-02-29t12:00:60z"] {
            XCTAssertNil(regex.firstMatch(in: rejected, range: NSRange(rejected.startIndex..., in: rejected)))
            assertStructural(candidateData(occurredAt: rejected), "invalid:occurredAt")
        }

        let earliest = try AgentEventEnvelope.decode(candidateData(occurredAt: "0001-01-01t00:00:00z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: earliest.occurredAt)
        XCTAssertEqual(components.year, 1)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1)
    }

    func testStrictJSONPreflightRejectsTrailingAndMalformedGrammar() {
        let base = candidateData()
        assertStructural(base + Data("{}".utf8), "invalidJSON")
        for malformed in ["{", "[] trailing", "{\"a\":01}", "{\"a\":1,}", "[1,]"] {
            assertStructural(Data(malformed.utf8), "invalidJSON")
        }
    }

    func testCandidateInputHasBoundedSizeAndNesting() {
        assertStructural(Data(repeating: 0x20, count: 1_048_577), "tooLarge")
        let deeplyNested = Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)
        assertStructural(deeplyNested, "tooDeep")
    }

    func testStrictPreflightFuzzNeverEscapesStructuralBoundary() {
        var state: UInt64 = 0xC0FFEE
        for length in 0..<256 {
            let bytes = (0..<length).map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 24)
            }
            XCTAssertFalse(structuralViolations(Data(bytes)).isEmpty)
        }
    }

    func testDirectCodableDecoderCannotBypassStructuralConstraints() {
        XCTAssertThrowsError(try JSONDecoder.travelCat.decode(
            AgentEventEnvelope.self,
            from: candidateData(moodLevel: 3)
        ))
        XCTAssertThrowsError(try JSONDecoder.travelCat.decode(
            AgentEventEnvelope.self,
            from: candidateData(references: ["锚点", "锚点"])
        ))
        let missingNullableLink = Data(String(decoding: candidateData(), as: UTF8.self)
            .replacingOccurrences(of: "\"previousEventId\":null,", with: "").utf8)
        XCTAssertThrowsError(try JSONDecoder.travelCat.decode(AgentEventEnvelope.self, from: missingNullableLink))
        let missingNullablePrompt = Data(String(decoding: candidateData(), as: UTF8.self)
            .replacingOccurrences(of: ",\"scenePrompt\":null", with: "").utf8)
        XCTAssertThrowsError(try JSONDecoder.travelCat.decode(AgentEventEnvelope.self, from: missingNullablePrompt))
    }

    func testDomainViolationsAreStableAndOrdered() throws {
        let previousEventID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let previous = TripSnapshot(
            stateVersion: 3,
            tripID: tripID,
            lastEventID: previousEventID,
            phase: .transit,
            nextActionAt: occurredAt,
            lastUpdatedAt: occurredAt,
            carriedItemID: "camera",
            usedItemIDs: ["used"],
            visitedPlaces: ["长谷寺"],
            mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )
        let candidate = try AgentEventEnvelope.decode(candidateData(
            tripID: UUID().uuidString,
            previousEventID: UUID().uuidString,
            phase: "resting",
            occurredAt: "2026-08-11T11:59:59Z",
            location: ("Japan", "Kamakura", "长谷寺"),
            consumedItem: "used"
        ))

        XCTAssertEqual(
            candidate.validationResult(previous: previous, mode: .fast, calendar: utcCalendar()).violations,
            [
                "illegalTransition:transit->resting",
                "previousEventMismatch",
                "tripMismatch",
                "itemAlreadyConsumed:used",
                "consumedItemMismatch",
                "locationForbidden:resting",
                "occurredAtBeforeSnapshot",
                "repeatedPlace",
            ]
        )
    }

    func testPostcardAndLocationRules() throws {
        let previous = TripSnapshot(
            stateVersion: 1, tripID: tripID, lastEventID: eventID, phase: .transit,
            nextActionAt: occurredAt, lastUpdatedAt: occurredAt, usedItemIDs: [], visitedPlaces: [],
            mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )
        let nextID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!.uuidString
        let noLocation = try AgentEventEnvelope.decode(candidateData(
            eventID: nextID, previousEventID: eventID.uuidString, phase: "exploring", location: nil
        ))
        XCTAssertEqual(noLocation.validationResult(previous: previous, mode: .fast, calendar: utcCalendar()).violations, ["locationRequired:exploring"])

        let badPostcard = try AgentEventEnvelope.decode(candidateData(
            eventID: nextID, previousEventID: eventID.uuidString, phase: "exploring",
            location: ("Japan", "Kamakura", "长谷寺"), postcardRequired: true, scenePrompt: "海边"
        ))
        XCTAssertEqual(badPostcard.validationResult(previous: previous, mode: .fast, calendar: utcCalendar()).violations, ["postcardPhaseMismatch"])
    }

    func testNewTripBoundaryAllowsConsumingSelectedItemFromPriorTripHistory() throws {
        let oldTrip = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        let previousEvent = UUID(uuidString: "30000000-0000-0000-0000-000000000008")!
        let previous = TripSnapshot(
            stateVersion: 8, tripID: oldTrip, lastEventID: previousEvent, phase: .resting,
            nextActionAt: occurredAt, lastUpdatedAt: occurredAt, carriedItemID: "matcha",
            usedItemIDs: ["matcha"], visitedPlaces: ["旧旅程终点"],
            mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )
        let candidate = try AgentEventEnvelope.decode(candidateData(
            previousEventID: previousEvent.uuidString,
            consumedItem: "matcha"
        ))

        let result = candidate.validationResult(previous: previous, mode: .fast, calendar: utcCalendar())

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.publishEnvelope?.next.usedItemIDs, ["matcha"])
        XCTAssertEqual(result.publishEnvelope?.next.visitedPlaces, [])
        XCTAssertNil(result.publishEnvelope?.next.carriedItemID)
    }

    func testSameTripStillRejectsReusingConsumedCarriedItem() throws {
        let previous = TripSnapshot(
            stateVersion: 1, tripID: tripID, lastEventID: eventID, phase: .preparing,
            nextActionAt: occurredAt, lastUpdatedAt: occurredAt, carriedItemID: "matcha",
            usedItemIDs: ["matcha"], visitedPlaces: [],
            mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )
        let candidate = try AgentEventEnvelope.decode(candidateData(
            eventID: "10000000-0000-0000-0000-000000000002",
            previousEventID: eventID.uuidString,
            phase: "transit",
            consumedItem: "matcha"
        ))

        XCTAssertEqual(
            candidate.validationResult(previous: previous, mode: .fast, calendar: utcCalendar()).violations,
            ["itemAlreadyConsumed:matcha"]
        )
    }

    func testRejectsLastAndHistoricalEventIDCollisions() throws {
        let historical = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
        let previous = TripSnapshot(
            stateVersion: 2, tripID: tripID, lastEventID: eventID, phase: .preparing,
            nextActionAt: occurredAt, lastUpdatedAt: occurredAt,
            usedItemIDs: [], visitedPlaces: [], mood: Mood(level: 0, label: "平静", quote: "今天适合慢一点。")
        )
        let lastCollision = try AgentEventEnvelope.decode(candidateData(
            previousEventID: eventID.uuidString, phase: "transit"
        ))
        XCTAssertEqual(
            lastCollision.validationResult(previous: previous, mode: .fast, calendar: utcCalendar()).violations,
            ["duplicateEventID"]
        )

        let historicalCollision = try AgentEventEnvelope.decode(candidateData(
            eventID: historical.uuidString, previousEventID: eventID.uuidString, phase: "transit"
        ))
        XCTAssertEqual(
            historicalCollision.validationResult(
                previous: previous,
                existingEventIDs: [historical],
                mode: .fast,
                calendar: utcCalendar()
            ).violations,
            ["duplicateEventID"]
        )
    }

    func testSchemaLengthsCountUnicodeScalarsRatherThanGraphemeClusters() throws {
        let decomposed = "e\u{301}"
        XCTAssertNoThrow(try AgentEventEnvelope.decode(candidateData(
            summary: String(repeating: decomposed, count: 10),
            quote: String(repeating: decomposed, count: 16),
            openHook: String(repeating: decomposed, count: 60),
            scenePrompt: String(repeating: decomposed, count: 250)
        )))
        assertStructural(
            candidateData(quote: String(repeating: decomposed, count: 17)),
            "length:mood.quote"
        )
        assertStructural(
            candidateData(openHook: String(repeating: decomposed, count: 61)),
            "length:openHook"
        )
        assertStructural(
            candidateData(scenePrompt: String(repeating: decomposed, count: 251)),
            "length:postcard.scenePrompt"
        )
    }

    func testValidationResultJSONHasStableShapeAndPublishRoundTrips() throws {
        let root = try temporaryDirectory()
        let repository = try TravelRepository(root: root, clock: FixedClock(now: occurredAt))
        let candidate = try AgentEventEnvelope.decode(candidateData())
        let result = candidate.validationResult(previous: try repository.loadSnapshot(), mode: .fast, calendar: utcCalendar())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(result)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["valid", "violations", "stateVersion", "publishEnvelope"])
        let publish = try XCTUnwrap(result.publishEnvelope)

        try repository.publish(event: publish.event, next: publish.next)

        XCTAssertEqual(try repository.loadSnapshot(), publish.next)
        XCTAssertEqual(try repository.events(), [publish.event])
    }

    private func assertStructural(_ data: Data, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let violations = structuralViolations(data, file: file, line: line)
        XCTAssertTrue(violations.contains(expected), "\(violations) did not contain \(expected)", file: file, line: line)
    }

    private func structuralViolations(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        do {
            _ = try AgentEventEnvelope.decode(data)
            XCTFail("Expected structural failure", file: file, line: line)
            return []
        } catch let AgentEnvelopeError.structural(violations) {
            return violations
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return []
        }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func candidateData(
        extraTopLevel: String = "",
        extraMood: String = "",
        eventID: String? = "10000000-0000-0000-0000-000000000001",
        tripID: String = "10000000-0000-0000-0000-000000000000",
        previousEventID: String? = nil,
        phase: String = "preparing",
        occurredAt: String = "2026-08-11T12:00:00Z",
        location: (String, String, String)? = nil,
        summary: String? = "黑猫把蓝围巾与旅行手册仔细收进行囊，准备沿着海岸寻找新的故事。",
        moodLevel: Int = 0,
        quote: String = "潮声会替今天记住方向。",
        references: [String] = ["窗边圈出的镰仓海岸线"],
        openHook: String? = "沿海岸寻找风里的答案",
        consumedItem: String? = nil,
        postcardRequired: Bool = false,
        scenePrompt: String? = nil
    ) -> Data {
        let eventField = eventID.map { "\"eventId\":\"\($0)\"," } ?? ""
        let previous = previousEventID.map { "\"\($0)\"" } ?? "null"
        let locationJSON = location.map { "{\"country\":\"\($0.0)\",\"city\":\"\($0.1)\",\"place\":\"\($0.2)\"}" } ?? "null"
        let summaryField = summary.map { "\"summary\":\"\($0)\"," } ?? ""
        let refs = references.map { "\"\($0)\"" }.joined(separator: ",")
        let item = consumedItem.map { "\"\($0)\"" } ?? "null"
        let hook = openHook.map { "\"\($0)\"" } ?? "null"
        let prompt = scenePrompt.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {\(extraTopLevel)\(eventField)"tripId":"\(tripID)","previousEventId":\(previous),"occurredAt":"\(occurredAt)","phase":"\(phase)","location":\(locationJSON),"transport":null,\(summaryField)"mood":{"level":\(moodLevel),"label":"平静","quote":"\(quote)"\(extraMood)},"continuityReferences":[\(refs)],"openHook":\(hook),"consumedItemId":\(item),"postcard":{"required":\(postcardRequired),"scenePrompt":\(prompt)}}
        """.utf8)
    }
}
