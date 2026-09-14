public struct ContinuityValidator: Sendable {
    public enum Violation: Error, Equatable, Sendable {
        case moodJump
        case itemAlreadyConsumed(String)
        case missingAnchorReference
        case repeatedPlace
    }

    public init() {}

    public func violations(event: TripEvent, previous: TripSnapshot) -> [Violation] {
        var result: [Violation] = []

        if differsByMoreThanOne(event.mood.level, previous.mood.level) {
            result.append(.moodJump)
        }

        if let itemID = event.consumedItemID, previous.usedItemIDs.contains(itemID) {
            result.append(.itemAlreadyConsumed(itemID))
        }

        if previous.stateVersion > 0, event.continuityReferences.isEmpty {
            result.append(.missingAnchorReference)
        }

        if let place = event.location?.place, place == previous.visitedPlaces.last {
            result.append(.repeatedPlace)
        }

        return result
    }

    private func differsByMoreThanOne(_ lhs: Int, _ rhs: Int) -> Bool {
        let difference = lhs >= rhs
            ? lhs.subtractingReportingOverflow(rhs)
            : rhs.subtractingReportingOverflow(lhs)
        return difference.overflow || difference.partialValue > 1
    }
}
