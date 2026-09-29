import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

@MainActor
final class HomeLocationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        return root
    }

    func testHTTPSLookupParsesCityWithoutRetainingIPAddress() async throws {
        let client = IPHomeLocationLookup { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ipwho.is/")
            XCTAssertEqual(request.timeoutInterval, 8)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(#"{"success":true,"ip":"192.0.2.1","city":"Guangzhou","region":"Guangdong","country":"China"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let candidate = try await client.lookup()
        XCTAssertEqual(candidate.city, "Guangzhou")
        XCTAssertEqual(candidate.country, "China")
    }

    func testFailedOrCitylessIPResponseDoesNotInventCity() async throws {
        for json in [#"{"success":false,"city":"Shanghai"}"#, #"{"success":true,"country":"China","city":""}"#] {
            let client = IPHomeLocationLookup { request in
                (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await client.lookup(); XCTFail("invalid city must not be used") }
            catch { }
        }
    }

    func testFirstLaunchDoesNotContactThirdPartyBeforeConsent() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = StubHomeLookup()
        let controller = HomeLocationController(store: .init(root: root), lookup: lookup, now: { self.date })
        await controller.refresh(force: true)
        XCTAssertNil(controller.state.location)
        XCTAssertFalse(controller.state.ipLookupEnabled)
        let calls = await lookup.calls
        XCTAssertEqual(calls, 0)
    }

    func testSuccessfulLookupIsCachedAcrossControllerRestart() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeLocationStore(root: root)
        let lookup = StubHomeLookup()
        let controller = HomeLocationController(store: store, lookup: lookup, now: { self.date })
        controller.setIPLookupEnabled(true)
        await controller.refresh()
        XCTAssertEqual(controller.state.location?.city, "Guangzhou")
        XCTAssertEqual(controller.state.location?.source, .ip)
        let reopened = HomeLocationController(store: store, lookup: lookup, now: { self.date.addingTimeInterval(3600) })
        await reopened.refresh()
        let calls = await lookup.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reopened.state.location, controller.state.location)
        let stored = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(stored.contains("192.0.2.1"))
    }

    func testTimeoutPreservesKnownCityAndCachesFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeLocationStore(root: root)
        let original = HomeLocation(city: "Guangzhou", source: .ip, provider: "ipwho.is", updatedAt: date.addingTimeInterval(-8 * 24 * 3600))
        try store.save(.init(location: original, ipLookupEnabled: true))
        let lookup = StubHomeLookup(fail: true)
        let controller = HomeLocationController(store: store, lookup: lookup, now: { self.date })
        await controller.refresh()
        XCTAssertEqual(controller.state.location, original)
        XCTAssertTrue(controller.errorMessage?.contains("超时") == true)
        XCTAssertEqual(try store.load().location, original)
        let restarted = HomeLocationController(store: store, lookup: lookup, now: { self.date.addingTimeInterval(60) })
        await restarted.refresh()
        let calls = await lookup.calls
        XCTAssertEqual(calls, 1)
    }

    func testManualHomeSurvivesProxyCandidateUntilExplicitlyApplied() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = StubHomeLookup(city: "Piscataway")
        let store = HomeLocationStore(root: root)
        let controller = HomeLocationController(store: store, lookup: lookup, now: { self.date })
        controller.setManualCity("广州")
        controller.setIPLookupEnabled(true)
        await controller.refresh()
        var calls = await lookup.calls
        XCTAssertEqual(calls, 0)
        await controller.refresh(force: true)
        calls = await lookup.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.state.location?.city, "广州")
        XCTAssertEqual(try store.load().location?.city, "广州")
        XCTAssertEqual(controller.proposedLocation?.city, "Piscataway")
        controller.useProposedLocation()
        XCTAssertEqual(controller.state.location?.city, "Piscataway")
        XCTAssertEqual(controller.state.location?.source, .ip)
    }

    func testManualEditDuringLookupCannotBeOverwrittenByLateResponse() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = HeldHomeLookup()
        let controller = HomeLocationController(store: .init(root: root), lookup: lookup, now: { self.date })
        controller.setIPLookupEnabled(true)
        let task = Task { await controller.refresh() }
        for _ in 0..<1000 {
            if await lookup.started { break }
            await Task.yield()
        }
        XCTAssertTrue(controller.isLocating)
        controller.setManualCity("广州")
        await lookup.finish()
        await task.value
        XCTAssertEqual(controller.state.location?.city, "广州")
        XCTAssertEqual(controller.state.location?.source, .manual)
        XCTAssertNil(controller.proposedLocation)
    }

    func testRequestHomeContextIsOptionalForLegacyDecodeAndRoundTrips() throws {
        let snapshot = TripSnapshot.empty(now: date)
        let home = HomeLocation(city: "广州", source: .manual, updatedAt: date)
        let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: snapshot, previousEvent: nil),
            recentEvents: [], phase: .preparing, homeLocation: home)
        let data = try JSONEncoder.travelCat.encode(request)
        XCTAssertEqual(try JSONDecoder.travelCat.decode(TravelEventRequest.self, from: data).homeLocation, home)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "homeLocation")
        old.removeValue(forKey: "isSupplemental")
        let legacy = try JSONDecoder.travelCat.decode(TravelEventRequest.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.homeLocation)
        XCTAssertFalse(legacy.isSupplemental)
    }

    func testPromptUsesExplicitHomeAndDoesNotInferOneFromHistory() {
        let prompt = TravelGenerationPrompts.narrative()
        XCTAssertTrue(prompt.contains("homeLocation"))
        XCTAssertTrue(prompt.contains("preparing, returning and resting"))
        XCTAssertTrue(prompt.contains("must never override homeLocation"))
        XCTAssertTrue(prompt.contains("without inventing a home city"))
    }
}

private actor StubHomeLookup: HomeLocationLookingUp {
    private(set) var calls = 0
    let fail: Bool
    let city: String
    init(fail: Bool = false, city: String = "Guangzhou") { self.fail = fail; self.city = city }
    func lookup() async throws -> HomeLocationCandidate {
        calls += 1
        if fail { throw URLError(.timedOut) }
        return HomeLocationCandidate(country: "China", region: "Guangdong", city: city)
    }
}

private actor HeldHomeLookup: HomeLocationLookingUp {
    private var continuation: CheckedContinuation<HomeLocationCandidate, Never>?
    private(set) var started = false
    func lookup() async throws -> HomeLocationCandidate {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func finish() {
        continuation?.resume(returning: .init(country: "United States", region: "New Jersey", city: "Piscataway"))
        continuation = nil
    }
}
