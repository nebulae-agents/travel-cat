import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class PetTravelPromptTests: XCTestCase {
    func testDetectsDeparturePostcardAndReturnInOccurredAtOrder() {
        let tripID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let departureID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let postcardID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let returnID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let location = Location(country: "日本", city: "鎌倉", place: "大仏")
        let mood = Mood(level: 3, label: "欣喜", quote: "海风把旅途写亮了。")

        let departure = event(
            id: departureID,
            tripID: tripID,
            occurredAt: 30,
            phase: .preparing,
            location: location,
            summary: "出发前把行囊整理妥当。"
        )
        let pendingPostcard = event(
            id: postcardID,
            tripID: tripID,
            occurredAt: 20,
            phase: .postcardReady,
            location: location,
            mood: mood,
            postcardStatus: .pendingImage
        )
        let readyPostcard = event(
            id: postcardID,
            tripID: tripID,
            occurredAt: 20,
            phase: .postcardReady,
            location: location,
            mood: mood,
            postcardStatus: .ready
        )
        let returned = event(
            id: returnID,
            tripID: tripID,
            occurredAt: 10,
            phase: .resting,
            mood: Mood(level: 1, label: "安心", quote: "回家真好。")
        )
        let previous = contents(events: [pendingPostcard])
        let current = contents(events: [returned, departure, readyPostcard])

        XCTAssertEqual(
            PetTravelPromptDetector.detect(previous: previous, current: current),
            [
                .returned(eventID: returnID, tripID: tripID, mood: returned.mood.label),
                .postcardReady(
                    eventID: postcardID,
                    tripID: tripID,
                    location: location,
                    mood: mood.label,
                    quote: mood.quote
                ),
                .departed(
                    eventID: departureID,
                    tripID: tripID,
                    location: location,
                    summary: departure.summary
                ),
            ]
        )
    }

    func testRejectsTransitExploringPendingUnavailableRejectedAndAlreadyReady() {
        let tripID = UUID()
        let alreadyReadyID = UUID()
        let cases: [(String, TripEvent, TripEvent?)] = [
            ("transit", event(tripID: tripID, phase: .transit), nil),
            ("exploring", event(tripID: tripID, phase: .exploring), nil),
            (
                "pendingImage",
                event(tripID: tripID, phase: .postcardReady, postcardStatus: .pendingImage),
                nil
            ),
            (
                "imageUnavailable",
                event(tripID: tripID, phase: .postcardReady, postcardStatus: .imageUnavailable),
                nil
            ),
            (
                "rejected",
                event(tripID: tripID, phase: .postcardReady, postcardStatus: .rejected),
                nil
            ),
            (
                "already-ready",
                event(id: alreadyReadyID, tripID: tripID, phase: .postcardReady, postcardStatus: .ready),
                event(id: alreadyReadyID, tripID: tripID, phase: .postcardReady, postcardStatus: .ready)
            ),
        ]

        for (name, currentEvent, previousEvent) in cases {
            let previous = contents(events: previousEvent.map { [$0] } ?? [])
            let current = contents(events: [currentEvent])
            XCTAssertEqual(
                PetTravelPromptDetector.detect(previous: previous, current: current),
                [],
                "unexpected prompt for \(name)"
            )
        }
    }

    func testPendingImageToReadyProducesOnePromptAndReplayProducesNone() {
        let eventID = UUID()
        let tripID = UUID()
        let pending = event(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .pendingImage
        )
        let ready = event(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .ready
        )
        let previous = contents(events: [pending])
        let current = contents(events: [ready])

        XCTAssertEqual(
            PetTravelPromptDetector.detect(previous: previous, current: current),
            [
                .postcardReady(
                    eventID: eventID,
                    tripID: tripID,
                    location: ready.location,
                    mood: ready.mood.label,
                    quote: ready.mood.quote
                )
            ]
        )
        XCTAssertEqual(PetTravelPromptDetector.detect(previous: current, current: current), [])
    }

    func testDuplicatePreviousEventIDFailsClosedWithoutGeneratingReadyPrompt() {
        let eventID = UUID()
        let tripID = UUID()
        let pending = event(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .pendingImage
        )
        let alreadyReady = event(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .ready
        )
        let current = event(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .ready
        )

        XCTAssertEqual(
            PetTravelPromptDetector.detect(
                previous: contents(events: [pending, alreadyReady]),
                current: contents(events: [current])
            ),
            []
        )
    }

    func testDuplicateCurrentEventIDFailsClosedWithoutGeneratingAnyPrompt() {
        let eventID = UUID()
        let tripID = UUID()
        let first = event(id: eventID, tripID: tripID, phase: .preparing)
        let duplicate = event(id: eventID, tripID: tripID, phase: .preparing)

        XCTAssertEqual(
            PetTravelPromptDetector.detect(
                previous: contents(events: []),
                current: contents(events: [first, duplicate])
            ),
            []
        )
    }

    func testNewAlreadyReadyEventProducesExactlyOnePostcardPrompt() {
        let eventID = UUID()
        let tripID = UUID()
        let ready = event(
            id: eventID,
            tripID: tripID,
            phase: .postcardReady,
            postcardStatus: .ready
        )

        XCTAssertEqual(
            PetTravelPromptDetector.detect(
                previous: contents(events: []),
                current: contents(events: [ready])
            ),
            [
                .postcardReady(
                    eventID: eventID,
                    tripID: tripID,
                    location: ready.location,
                    mood: ready.mood.label,
                    quote: ready.mood.quote
                )
            ]
        )
    }

    func testDepartedAndReturnedCurrentReplayProducesNoPrompts() {
        let tripID = UUID()
        let departed = event(tripID: tripID, phase: .preparing)
        let returned = event(tripID: tripID, phase: .resting)
        let current = contents(events: [departed, returned])

        XCTAssertEqual(PetTravelPromptDetector.detect(previous: current, current: current), [])
    }

    func testIdentifiersAreLowercaseStableAndCodableRoundTrip() throws {
        let eventID = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!
        let tripID = UUID(uuidString: "FEDCBAFE-DCBA-FEDC-BAFE-DCBAFEDCBAFE")!
        let location = Location(country: "中国", city: "杭州", place: "西湖")
        let prompts: [PetTravelPrompt] = [
            .departed(eventID: eventID, tripID: tripID, location: location, summary: "出发"),
            .postcardReady(
                eventID: eventID,
                tripID: tripID,
                location: location,
                mood: "好奇",
                quote: "去看看。"
            ),
            .returned(eventID: eventID, tripID: tripID, mood: "安心"),
        ]
        let expected = [
            "pet-departed-abcdefab-cdef-abcd-efab-cdefabcdefab",
            "pet-postcard-abcdefab-cdef-abcd-efab-cdefabcdefab",
            "pet-returned-fedcbafe-dcba-fedc-bafe-dcbafedcbafe-abcdefab-cdef-abcd-efab-cdefabcdefab",
        ]

        XCTAssertEqual(prompts.map(\.identifier), expected)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for prompt in prompts {
            XCTAssertEqual(try decoder.decode(PetTravelPrompt.self, from: encoder.encode(prompt)), prompt)
        }
    }

    func testEqualOccurredAtKeepsCurrentJournalOrder() {
        let tripID = UUID()
        let first = event(id: UUID(), tripID: tripID, occurredAt: 50, phase: .resting)
        let second = event(id: UUID(), tripID: tripID, occurredAt: 50, phase: .preparing)
        let current = contents(events: [first, second])

        XCTAssertEqual(
            PetTravelPromptDetector.detect(previous: contents(events: []), current: current),
            [
                .returned(eventID: first.id, tripID: tripID, mood: first.mood.label),
                .departed(
                    eventID: second.id,
                    tripID: tripID,
                    location: second.location,
                    summary: second.summary
                ),
            ]
        )
    }

    private func contents(events: [TripEvent]) -> RepositoryContents {
        RepositoryContents(snapshot: .fixture(), events: events)
    }

    private func event(
        id: UUID = UUID(),
        tripID: UUID = UUID(),
        occurredAt: TimeInterval = 100,
        phase: TravelPhase,
        location: Location? = nil,
        summary: String = "黑猫准备踏上旅途。",
        mood: Mood = .init(level: 1, label: "期待", quote: "想看看风会把我带去哪里。"),
        postcardStatus: PostcardStatus = .none
    ) -> TripEvent {
        .init(
            id: id,
            tripID: tripID,
            previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: occurredAt),
            phase: phase,
            location: location,
            transport: nil,
            summary: summary,
            mood: mood,
            continuityReferences: [],
            openHook: nil,
            consumedItemID: nil,
            postcardStatus: postcardStatus,
            postcardRelativePath: nil
        )
    }
}
