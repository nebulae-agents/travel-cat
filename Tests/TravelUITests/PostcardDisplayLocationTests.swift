import Foundation
import XCTest
import TravelCore
@testable import TravelUI

final class PostcardDisplayLocationTests: XCTestCase {
    private let resolver = PostcardDisplayLocation()

    func testResolvesExactStructuredAliasesAfterTrimmingInput() {
        let cases = [
            (Location(country: " Japan ", city: " Otsu ", place: " Otsu Port old pier "), "大津港旧栈桥"),
            (Location(country: "\nJapan", city: "Hatsukaichi\t", place: " Itsukushima Shrine O-Torii "), "宫岛大鸟居"),
            (Location(country: "Japan ", city: " Matsumoto", place: "\nKappa Bridge\t"), "上高地河童桥"),
        ]

        for (location, expected) in cases {
            XCTAssertEqual(resolver.resolve(location), expected)
        }
    }

    func testPreservesPlaceWhenOnlyNameCollidesWithKnownAlias() {
        let location = Location(country: "USA", city: "Somewhere", place: " Kappa Bridge ")

        XCTAssertEqual(resolver.resolve(location), "Kappa Bridge")
    }

    func testPreservesTrimmedUnknownPlaceWithoutGuessingOrContainsMatching() {
        let location = Location(
            country: "Japan",
            city: "Kamikochi",
            place: "  Old Kappa Bridge Annex  "
        )

        XCTAssertEqual(resolver.resolve(location), "Old Kappa Bridge Annex")
    }

    func testResolvesSuzhouMasterOfTheNetsGardenToShortChineseAliasAcrossInputForms() {
        let locations = [
            Location(country: "China", city: "Suzhou", place: "Master of the Nets Garden"),
            Location(country: " 中国 ", city: " 苏州 ", place: " Master of the Nets Garden "),
            Location(country: "CHINA", city: "SUZHOU", place: "MASTER OF THE NETS GARDEN"),
        ]

        for location in locations {
            XCTAssertEqual(resolver.resolve(location), "苏州·网师园")
        }
    }

    func testCompactResolutionShortensUnknownDisplayNameButSpokenResolutionKeepsOriginal() {
        let location = Location(
            country: "United Kingdom",
            city: "London",
            place: "A Very Long Untranslated Place Name That Must Stay Intact"
        )

        XCTAssertEqual(
            resolver.resolveCompact(location, maximumLength: 20),
            "A Very Long Untrans…"
        )
        XCTAssertEqual(
            resolver.resolveSpoken(location),
            "United Kingdom · London · A Very Long Untranslated Place Name That Must Stay Intact"
        )
    }

    func testFallsBackFromBlankPlaceToCityThenCountryThenJourney() {
        XCTAssertEqual(
            resolver.resolve(Location(country: " Japan ", city: " Otsu ", place: " \n ")),
            "Otsu"
        )
        XCTAssertEqual(
            resolver.resolve(Location(country: " Japan ", city: "\t", place: "")),
            "Japan"
        )
        XCTAssertEqual(
            resolver.resolve(Location(country: " ", city: "\n", place: "\t")),
            "旅途中"
        )
        XCTAssertEqual(resolver.resolve(nil), "旅途中")
    }

    func testResolverIsSendableAndDeterministic() {
        assertSendable(resolver)
        let location = Location(country: "Japan", city: "Kyoto", place: "Unknown Place")

        XCTAssertEqual(resolver.resolve(location), resolver.resolve(location))
        XCTAssertEqual(resolver.resolve(location), PostcardDisplayLocation().resolve(location))
    }

    func testCreatingArtworkMetadataDoesNotChangeEncodedTripEventBytes() throws {
        let event = TripEvent(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            tripID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            previousEventID: UUID(uuidString: "33333333-3333-3333-3333-333333333333"),
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            phase: .postcardReady,
            location: Location(country: "Japan", city: "Otsu", place: "Otsu Port old pier"),
            transport: "train",
            summary: "A postcard arrived.",
            mood: Mood(level: 2, label: "curious", quote: "The lake is bright."),
            continuityReferences: ["lake"],
            openHook: "Follow the shoreline.",
            consumedItemID: "snack",
            postcardStatus: .ready,
            postcardRelativePath: "postcards/trip/card.webp"
        )
        let bytesBeforeMetadata = try JSONEncoder.travelCat.encode(event)

        let metadata = PostcardArtworkMetadata(event: event)

        XCTAssertEqual(metadata.locationLabel, "大津港旧栈桥")
        XCTAssertEqual(try JSONEncoder.travelCat.encode(event), bytesBeforeMetadata)
    }

    private func assertSendable<T: Sendable>(_: T) {}
}
