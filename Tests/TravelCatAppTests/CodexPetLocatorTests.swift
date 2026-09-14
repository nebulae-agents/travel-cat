import CoreGraphics
import XCTest
@testable import TravelCatApp

final class CodexPetLocatorTests: XCTestCase {
    private let primaryScreen = CodexScreenRecord(
        frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        visibleFrame: CGRect(x: 0, y: 40, width: 1_000, height: 736)
    )
    private let rightScreen = CodexScreenRecord(
        frame: CGRect(x: 1_000, y: 0, width: 800, height: 800),
        visibleFrame: CGRect(x: 1_000, y: 40, width: 800, height: 736)
    )

    func testDictionaryInitializerExtractsEveryTypedWindowField() throws {
        let bounds = CGRect(x: 120, y: 45, width: 243, height: 253)

        let record = try XCTUnwrap(CodexWindowRecord(dictionary: dictionary(
            number: 113,
            ownerPID: 1_129,
            owner: "ChatGPT",
            name: "Codex Pet Mascot Effect",
            layer: 2,
            alpha: 0.75,
            bounds: bounds
        )))

        XCTAssertEqual(record.number, 113)
        XCTAssertEqual(record.ownerPID, 1_129)
        XCTAssertEqual(record.owner, "ChatGPT")
        XCTAssertEqual(record.name, "Codex Pet Mascot Effect")
        XCTAssertEqual(record.layer, 2)
        XCTAssertEqual(record.alpha, 0.75)
        XCTAssertEqual(record.bounds, bounds)
    }

    func testDictionaryInitializerRejectsEveryMissingField() {
        let complete = dictionary()
        let requiredKeys = [
            kCGWindowNumber as String,
            kCGWindowOwnerPID as String,
            kCGWindowOwnerName as String,
            kCGWindowLayer as String,
            kCGWindowAlpha as String,
            kCGWindowBounds as String,
        ]

        for key in requiredKeys {
            var incomplete = complete
            incomplete.removeValue(forKey: key)
            XCTAssertNil(CodexWindowRecord(dictionary: incomplete), "accepted missing \(key)")
        }
    }

    func testDictionaryInitializerTreatsPrivacyOmittedWindowNameAsRedacted() throws {
        var redacted = dictionary()
        redacted.removeValue(forKey: kCGWindowName as String)

        let record = try XCTUnwrap(CodexWindowRecord(dictionary: redacted))

        XCTAssertEqual(record.name, "")
    }

    func testDictionaryInitializerRejectsWrongTypesAndMalformedBounds() {
        let invalidValues: [(String, Any)] = [
            (kCGWindowNumber as String, "113"),
            (kCGWindowOwnerPID as String, "1129"),
            (kCGWindowOwnerName as String, 7),
            (kCGWindowName as String, 7),
            (kCGWindowLayer as String, "2"),
            (kCGWindowAlpha as String, "1"),
            (kCGWindowBounds as String, "not-a-rectangle"),
        ]

        for (key, value) in invalidValues {
            var malformed = dictionary()
            malformed[key] = value
            XCTAssertNil(CodexWindowRecord(dictionary: malformed), "accepted malformed \(key)")
        }
    }

    func testDictionaryInitializerRejectsBridgedBooleansForNumericFields() {
        for key in [
            kCGWindowNumber as String,
            kCGWindowOwnerPID as String,
            kCGWindowLayer as String,
            kCGWindowAlpha as String,
        ] {
            var malformed = dictionary()
            malformed[key] = NSNumber(value: true)
            XCTAssertNil(CodexWindowRecord(dictionary: malformed), "accepted Boolean \(key)")
        }
    }

    func testDictionaryInitializerRejectsNonpositiveFractionalOrOverflowingOwnerPID() {
        let invalidPIDs: [Any] = [
            0,
            -1,
            1_129.5,
            NSNumber(value: Int64(Int32.max) + 1),
            Double.nan,
            Double.infinity,
        ]

        for ownerPID in invalidPIDs {
            var malformed = dictionary()
            malformed[kCGWindowOwnerPID as String] = ownerPID
            XCTAssertNil(CodexWindowRecord(dictionary: malformed), "accepted owner PID \(ownerPID)")
        }
    }

    func testDictionaryInitializerRejectsNonfiniteAlphaOrBounds() {
        var invalidAlpha = dictionary()
        invalidAlpha[kCGWindowAlpha as String] = Double.nan
        XCTAssertNil(CodexWindowRecord(dictionary: invalidAlpha))

        for bounds in [
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
        ] {
            XCTAssertNil(CodexWindowRecord(dictionary: dictionary(bounds: bounds)))
        }
    }

    func testDictionaryInitializerRejectsMalformedNestedBoundsWithoutThrowing() {
        let malformedBounds: [[String: Any]] = [
            ["X": "1", "Y": 100, "Width": 120, "Height": 140],
            ["X": 100, "Y": NSNumber(value: true), "Width": 120, "Height": 140],
            ["X": 100, "Y": 100, "Width": "120", "Height": 140],
            ["X": 100, "Y": 100, "Width": 120, "Height": NSNull()],
            ["Y": 100, "Width": 120, "Height": 140],
        ]

        for bounds in malformedBounds {
            var malformed = dictionary()
            malformed[kCGWindowBounds as String] = bounds
            XCTAssertNil(CodexWindowRecord(dictionary: malformed), "accepted bounds \(bounds)")
        }
    }

    func testDictionaryInitializerRejectsNonfiniteOrNonpositiveRawBoundsNumbers() {
        let invalidValues: [(String, Any)] = [
            ("X", Double.nan),
            ("Y", Double.infinity),
            ("Width", Double.nan),
            ("Height", -Double.infinity),
            ("Width", 0),
            ("Height", 0),
            ("Width", -1),
            ("Height", -1),
        ]

        for (key, value) in invalidValues {
            var bounds: [String: Any] = ["X": 100, "Y": 100, "Width": 120, "Height": 140]
            bounds[key] = value
            var malformed = dictionary()
            malformed[kCGWindowBounds as String] = bounds
            XCTAssertNil(CodexWindowRecord(dictionary: malformed), "accepted raw bounds \(bounds)")
        }
    }

    func testMascotValidationRequiresExactOwnerNameVisibleLayerAlphaAndSaneBounds() {
        XCTAssertTrue(makeRecord().isValidMascot)

        let rejected = [
            makeRecord(owner: "ChatGPT "),
            makeRecord(owner: "Other"),
            makeRecord(name: "Codex Pet Mascot Effect "),
            makeRecord(name: "Codex Pet Voice Controls Glass"),
            makeRecord(name: "Codex Pet Composition Window"),
            makeRecord(layer: -1),
            makeRecord(alpha: 0),
            makeRecord(alpha: -0.1),
            makeRecord(bounds: CGRect(x: 0, y: 0, width: 0, height: 100)),
            makeRecord(bounds: CGRect(x: 0, y: 0, width: 100, height: 0)),
            makeRecord(bounds: CGRect(x: 0, y: 0, width: -1, height: 100)),
            makeRecord(bounds: CGRect(x: 0, y: 0, width: 100, height: -1)),
            makeRecord(bounds: CGRect(x: 0, y: 0, width: 1_025, height: 100)),
            makeRecord(bounds: CGRect(x: 0, y: 0, width: 100, height: 1_025)),
            makeRecord(bounds: CGRect(x: 100_001, y: 0, width: 100, height: 100)),
            makeRecord(bounds: CGRect(x: -100_001, y: 0, width: 100, height: 100)),
            makeRecord(bounds: CGRect(x: 0, y: 100_001, width: 100, height: 100)),
            makeRecord(bounds: CGRect(x: 0, y: -100_001, width: 100, height: 100)),
        ]

        for invalidRecord in rejected {
            XCTAssertFalse(invalidRecord.isValidMascot, "accepted \(invalidRecord)")
        }
    }

    func testMascotValidationAcceptsNegativeCoordinatesAndExactLimits() {
        XCTAssertTrue(makeRecord(
            bounds: CGRect(x: -100_000, y: -100_000, width: 1_024, height: 1_024)
        ).isValidMascot)
    }

    func testExactMascotWindowWinsAndVoiceCompositionOrWrongOwnerSurfacesAreRejected() throws {
        let mascot = makeRecord(number: 113)
        let records = [
            makeRecord(number: 1, name: "Codex Pet Voice Controls Glass"),
            makeRecord(number: 2, name: "Codex Pet Composition Window"),
            makeRecord(number: 3, owner: "Other"),
            mascot,
        ]

        let selection = try XCTUnwrap(select(
            records: records,
            mouseLocation: .zero,
            screens: [primaryScreen]
        ))

        XCTAssertEqual(selection.record, mascot)
    }

    func testLegacyExactSignatureRequiresBundleTrust() throws {
        let mascot = makeRecord(number: 113, ownerPID: 99_001)
        var resolverCalls = 0

        let selection = select(
            records: [mascot],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in
                resolverCalls += 1
                return nil
            }
        )

        XCTAssertNil(selection)
        XCTAssertEqual(resolverCalls, 1)
    }

    func testPrivacyRedactedWindowCannotIdentifyCurrentPetEvenWhenTrusted() throws {
        let redactedMascot = makeRecord(
            number: 17748,
            ownerPID: 2_101,
            name: "",
            layer: 2,
            bounds: CGRect(x: 1_292, y: 64, width: 215, height: 224)
        )

        let selection = select(
            records: [redactedMascot],
            mouseLocation: .zero,
            screens: [CodexScreenRecord(
                frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_469, height: 949)
            )],
            bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
        )

        XCTAssertNil(selection)
    }

    func testPrivacyRedactedFallbackRejectsAuxiliaryLayersAndUntrustedOwners() {
        for layer in [0, 1, 3] {
            let auxiliary = makeRecord(
                ownerPID: 2_101,
                name: "",
                layer: layer,
                bounds: CGRect(x: 200, y: 100, width: 215, height: 224)
            )
            XCTAssertNil(select(
                records: [auxiliary],
                mouseLocation: .zero,
                screens: [primaryScreen],
                bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
            ))
        }

        let untrusted = makeRecord(
            ownerPID: 44_001,
            name: "",
            layer: 2,
            bounds: CGRect(x: 200, y: 100, width: 215, height: 224)
        )
        XCTAssertNil(select(
            records: [untrusted],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in "com.example.spoof" }
        ))
    }

    func testNamedMascotWinsOverPrivacyRedactedFallback() throws {
        let namedMascot = makeRecord(
            number: 17748,
            ownerPID: 2_101,
            bounds: CGRect(x: 100, y: 100, width: 215, height: 224)
        )
        let redactedFallback = makeRecord(
            number: 7,
            ownerPID: 2_101,
            name: "",
            layer: 2,
            bounds: CGRect(x: 1_050, y: 100, width: 215, height: 224)
        )

        let selection = try XCTUnwrap(select(
            records: [redactedFallback, namedMascot],
            mouseLocation: CGPoint(x: 1_200, y: 400),
            screens: [primaryScreen, rightScreen],
            bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
        ))

        XCTAssertEqual(selection.record, namedMascot)
    }

    func testMultiplePrivacyRedactedCandidatesFailClosed() {
        let first = makeRecord(
            number: 7,
            ownerPID: 2_101,
            name: "",
            layer: 2,
            bounds: CGRect(x: 100, y: 100, width: 215, height: 224)
        )
        let second = makeRecord(
            number: 8,
            ownerPID: 2_101,
            name: "",
            layer: 2,
            bounds: CGRect(x: 1_050, y: 100, width: 215, height: 224)
        )

        XCTAssertNil(select(
            records: [first, second],
            mouseLocation: CGPoint(x: 1_200, y: 400),
            screens: [primaryScreen, rightScreen],
            bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
        ))
    }

    func testOrdinaryChatGPTWindowCannotIdentifyCurrentPetEvenWhenTrusted() throws {
        let mascot = makeRecord(
            number: 102,
            ownerPID: 1_129,
            name: "ChatGPT",
            layer: 0,
            bounds: CGRect(x: 200, y: 100, width: 144, height: 180)
        )
        var resolvedPIDs: [pid_t] = []

        let selection = select(
            records: [mascot],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { ownerPID in
                resolvedPIDs.append(ownerPID)
                return "com.openai.codex"
            }
        )

        XCTAssertNil(selection)
    }

    func testCurrentSignatureFailsClosedForMissingOrWrongBundleTrust() {
        let mascot = makeRecord(
            number: 102,
            ownerPID: 1_129,
            name: "ChatGPT",
            layer: 0,
            bounds: CGRect(x: 200, y: 100, width: 144, height: 180)
        )

        XCTAssertNil(select(
            records: [mascot],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in nil }
        ))
        XCTAssertNil(select(
            records: [mascot],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in "com.openai.chatgpt" }
        ))
    }

    func testCurrentSignatureRejectsMainCompositionAuxiliaryAndSameNameSpoofWindows() {
        let rejected = [
            makeRecord(ownerPID: 1_129, name: "ChatGPT", layer: 0, bounds: CGRect(x: 20, y: 20, width: 900, height: 700)),
            makeRecord(ownerPID: 1_129, name: "ChatGPT", layer: 0, bounds: CGRect(x: 20, y: 20, width: 500, height: 500)),
            makeRecord(ownerPID: 1_129, name: "ChatGPT", layer: 0, bounds: CGRect(x: 20, y: 20, width: 1_512, height: 33)),
            makeRecord(ownerPID: 1_129, name: "ChatGPT", layer: 0, bounds: CGRect(x: 20, y: 20, width: 144, height: 33)),
            makeRecord(ownerPID: 1_129, owner: "Other", name: "ChatGPT", layer: 0, bounds: CGRect(x: 20, y: 20, width: 144, height: 180)),
        ]

        for record in rejected {
            XCTAssertNil(select(
                records: [record],
                mouseLocation: .zero,
                screens: [primaryScreen],
                bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
            ), "accepted non-pet surface \(record)")
        }

        let sameNameSpoof = makeRecord(
            ownerPID: 44_001,
            name: "ChatGPT",
            layer: 0,
            bounds: CGRect(x: 20, y: 20, width: 144, height: 180)
        )
        XCTAssertNil(select(
            records: [sameNameSpoof],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in "com.example.spoof" }
        ))
    }

    func testRenamedPetLabelIsNotSufficientToIdentifyCurrentPet() throws {
        let mascot = makeRecord(
            ownerPID: 1_129,
            owner: "ChatGPT",
            name: "Cute Black Cat",
            layer: 0,
            bounds: CGRect(x: 200, y: 100, width: 144, height: 180)
        )

        let selection = select(
            records: [mascot],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
        )

        XCTAssertNil(selection)
    }

    func testCapitalizedAndSuffixedPetLabelCannotIdentifyCurrentPet() throws {
        let mascot = makeRecord(
            ownerPID: 1_129,
            owner: "chatgpt",
            name: "Cute Black Cat Mascot Window",
            layer: 0,
            bounds: CGRect(x: 200, y: 100, width: 144, height: 180)
        )

        let selection = select(
            records: [mascot],
            mouseLocation: .zero,
            screens: [primaryScreen],
            bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
        )

        XCTAssertNil(selection)
    }

    func testSimilarCurrentWindowsAllFailClosedRegardlessOfOrder() throws {
        let records = [91, 7, 42].map {
            makeRecord(
                number: $0,
                ownerPID: 1_129,
                name: "ChatGPT",
                layer: 0,
                bounds: CGRect(x: 200, y: 100, width: 144, height: 180)
            )
        }

        for ordering in [records, Array(records.reversed())] {
            let selection = select(
                records: ordering,
                mouseLocation: .zero,
                screens: [primaryScreen],
                bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
            )
            XCTAssertNil(selection)
        }
    }

    func testCGToAppKitConversionUsesPrimaryScreenMaximumY() {
        XCTAssertEqual(
            CodexPetLocator.appKitBounds(
                from: CGRect(x: -200, y: 125, width: 120, height: 140),
                primaryFrame: CGRect(x: 0, y: -50, width: 1_000, height: 850)
            ),
            CGRect(x: -200, y: 535, width: 120, height: 140)
        )
    }

    func testSelectionPrefersCandidateOnMouseScreenBeforeLargerOverlap() throws {
        let mouseScreenCandidate = makeRecord(
            number: 50,
            bounds: cgBounds(forAppKit: CGRect(x: 1_050, y: 300, width: 80, height: 80))
        )
        let largerPrimaryCandidate = makeRecord(
            number: 1,
            bounds: cgBounds(forAppKit: CGRect(x: 100, y: 200, width: 300, height: 300))
        )

        let selection = try XCTUnwrap(select(
            records: [largerPrimaryCandidate, mouseScreenCandidate],
            mouseLocation: CGPoint(x: 1_400, y: 400),
            screens: [primaryScreen, rightScreen]
        ))

        XCTAssertEqual(selection.record, mouseScreenCandidate)
        XCTAssertEqual(selection.screenFrame, rightScreen.visibleFrame)
    }

    func testMousePriorityUsesAnyMascotIntersectionWithMouseScreen() throws {
        let spanningCandidate = makeRecord(
            number: 90,
            bounds: cgBounds(forAppKit: CGRect(x: 950, y: 300, width: 300, height: 100))
        )
        let primaryOnlyCandidate = makeRecord(
            number: 1,
            bounds: cgBounds(forAppKit: CGRect(x: 100, y: 300, width: 100, height: 100))
        )

        let selection = try XCTUnwrap(select(
            records: [primaryOnlyCandidate, spanningCandidate],
            mouseLocation: CGPoint(x: 500, y: 400),
            screens: [primaryScreen, rightScreen]
        ))

        XCTAssertEqual(selection.record, spanningCandidate)
        XCTAssertEqual(selection.screenFrame, rightScreen.visibleFrame)
    }

    func testSelectionThenPrefersLargestFullScreenIntersectionArea() throws {
        let smaller = makeRecord(
            number: 1,
            bounds: cgBounds(forAppKit: CGRect(x: 950, y: 300, width: 100, height: 100))
        )
        let larger = makeRecord(
            number: 90,
            bounds: cgBounds(forAppKit: CGRect(x: 850, y: 300, width: 140, height: 100))
        )

        let selection = try XCTUnwrap(select(
            records: [smaller, larger],
            mouseLocation: CGPoint(x: -500, y: -500),
            screens: [primaryScreen, rightScreen]
        ))

        XCTAssertEqual(selection.record, larger)
        XCTAssertEqual(selection.screenFrame, primaryScreen.visibleFrame)
    }

    func testDuplicateTieUsesLowestWindowNumberRegardlessOfInputOrder() throws {
        let records = [makeRecord(number: 91), makeRecord(number: 7), makeRecord(number: 42)]

        for ordering in [records, Array(records.reversed())] {
            let selection = try XCTUnwrap(select(
                records: ordering,
                mouseLocation: .zero,
                screens: [primaryScreen]
            ))
            XCTAssertEqual(selection.record?.number, 7)
        }
    }

    func testEqualScreenOverlapUsesFirstValidScreenDeterministically() throws {
        let spanning = makeRecord(
            bounds: cgBounds(forAppKit: CGRect(x: 950, y: 300, width: 100, height: 100))
        )

        let selection = try XCTUnwrap(select(
            records: [spanning],
            mouseLocation: CGPoint(x: -500, y: -500),
            screens: [primaryScreen, rightScreen]
        ))

        XCTAssertEqual(selection.screenFrame, primaryScreen.visibleFrame)
    }

    func testNegativeCoordinateScreenCanBeSelected() throws {
        let leftScreen = CodexScreenRecord(
            frame: CGRect(x: -800, y: -100, width: 800, height: 900),
            visibleFrame: CGRect(x: -800, y: -60, width: 800, height: 820)
        )
        let mascot = makeRecord(
            bounds: cgBounds(forAppKit: CGRect(x: -240, y: 300, width: 120, height: 140))
        )

        let selection = try XCTUnwrap(select(
            records: [mascot],
            mouseLocation: CGPoint(x: -400, y: 400),
            screens: [primaryScreen, leftScreen]
        ))

        XCTAssertEqual(selection.record, mascot)
        XCTAssertEqual(selection.appKitBounds, CGRect(x: -240, y: 300, width: 120, height: 140))
        XCTAssertEqual(selection.screenFrame, leftScreen.visibleFrame)
    }

    func testInvalidSecondaryScreensAreIgnored() throws {
        let invalidScreens = [
            CodexScreenRecord(
                frame: CGRect(x: 0, y: 0, width: 0, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 800)
            ),
            CodexScreenRecord(
                frame: CGRect(x: 2_000, y: 0, width: 800, height: 800),
                visibleFrame: CGRect(x: 2_000, y: 0, width: 800, height: CGFloat.infinity)
            ),
            CodexScreenRecord(
                frame: CGRect(x: 2_000, y: 0, width: 800, height: 800),
                visibleFrame: CGRect(x: 1_900, y: 0, width: 900, height: 800)
            ),
        ]

        let selection = try XCTUnwrap(select(
            records: [makeRecord()],
            mouseLocation: .zero,
            screens: [primaryScreen] + invalidScreens
        ))

        XCTAssertEqual(selection.screenFrame, primaryScreen.visibleFrame)
    }

    func testInvalidPrimaryScreenFailsClosedEvenWhenAnotherScreenIsValid() {
        let invalidPrimaryScreens = [
            CodexScreenRecord(
                frame: CGRect(x: CGFloat.nan, y: 0, width: 1_000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            ),
            CodexScreenRecord(
                frame: CGRect(x: 0, y: 0, width: 0, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            ),
            CodexScreenRecord(
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: -1)
            ),
            CodexScreenRecord(
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_001, height: 800)
            ),
        ]

        for invalidPrimary in invalidPrimaryScreens {
            XCTAssertNil(select(
                records: [makeRecord()],
                mouseLocation: .zero,
                screens: [invalidPrimary, primaryScreen]
            ))
        }
        XCTAssertNil(select(records: [makeRecord()], mouseLocation: .zero, screens: []))
    }

    func testSelectionIntersectsFullFrameButReturnsVisibleFrameForLayout() throws {
        let insetScreen = CodexScreenRecord(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 60, width: 1_000, height: 716)
        )
        let mascotInDockInset = makeRecord(
            bounds: cgBounds(forAppKit: CGRect(x: 100, y: 10, width: 120, height: 30))
        )

        let selection = try XCTUnwrap(select(
            records: [mascotInDockInset],
            mouseLocation: CGPoint(x: 200, y: 20),
            screens: [insetScreen]
        ))

        XCTAssertEqual(selection.appKitBounds, CGRect(x: 100, y: 10, width: 120, height: 30))
        XCTAssertEqual(selection.screenFrame, insetScreen.visibleFrame)
        XCTAssertFalse(insetScreen.visibleFrame.intersects(selection.appKitBounds))
    }

    func testMouseScreenIdentityUsesFullFrameIncludingMenuBarInset() throws {
        let primaryCandidate = makeRecord(
            number: 90,
            bounds: cgBounds(forAppKit: CGRect(x: 100, y: 650, width: 100, height: 100))
        )
        let largerRightCandidate = makeRecord(
            number: 1,
            bounds: cgBounds(forAppKit: CGRect(x: 1_100, y: 300, width: 300, height: 300))
        )

        let selection = try XCTUnwrap(select(
            records: [largerRightCandidate, primaryCandidate],
            mouseLocation: CGPoint(x: 500, y: 790),
            screens: [primaryScreen, rightScreen]
        ))

        XCTAssertEqual(selection.record, primaryCandidate)
        XCTAssertEqual(selection.screenFrame, primaryScreen.visibleFrame)
    }

    func testSelectionRejectsMascotOutsideEveryValidScreen() {
        let outside = makeRecord(
            bounds: cgBounds(forAppKit: CGRect(x: 5_000, y: 5_000, width: 120, height: 140))
        )

        XCTAssertNil(select(
            records: [outside],
            mouseLocation: .zero,
            screens: [primaryScreen, rightScreen]
        ))
    }

    private func select(
        records: [CodexWindowRecord],
        mouseLocation: CGPoint,
        screens: [CodexScreenRecord],
        bundleIdentifierForOwnerPID: (pid_t) -> String? = { _ in "com.openai.codex" }
    ) -> CodexPetSelection? {
        CodexPetLocator.select(
            records: records,
            mouseLocation: mouseLocation,
            screens: screens,
            bundleIdentifierForOwnerPID: bundleIdentifierForOwnerPID
        )
    }

    private func makeRecord(
        number: Int = 113,
        ownerPID: pid_t = 1_129,
        owner: String = "ChatGPT",
        name: String = "Codex Pet Mascot Effect",
        layer: Int = 2,
        alpha: Double = 1,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 120, height: 140)
    ) -> CodexWindowRecord {
        CodexWindowRecord(
            number: number,
            ownerPID: ownerPID,
            owner: owner,
            name: name,
            layer: layer,
            alpha: alpha,
            bounds: bounds
        )
    }

    private func dictionary(
        number: Any = 113,
        ownerPID: Any = 1_129,
        owner: Any = "ChatGPT",
        name: Any = "Codex Pet Mascot Effect",
        layer: Any = 2,
        alpha: Any = 1.0,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 120, height: 140)
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: number,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowOwnerName as String: owner,
            kCGWindowName as String: name,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }

    private func cgBounds(forAppKit bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: primaryScreen.frame.maxY - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }
}
