import Darwin
import Foundation
import TravelCore
import TravelStorage
import TravelUI

@main
enum TravelCatCLI {
    private static let usage = "usage: travelcatctl status|journal|claim|publish|pending-images|prepare-postcard|mark-image|validate-candidate|character|configure-character|install-default-pet\n"

    static func main() {
        do {
            try run()
        } catch {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let isInteractiveCharacterCommand = arguments == [TravelCLICommand.character.rawValue]
                || arguments == [TravelCLICommand.configureCharacter.rawValue]
                || arguments == [TravelCLICommand.preparePostcard.rawValue]
            if case RepositoryError.lockUnavailable = error, isInteractiveCharacterCommand {
                writeStandardError("travelcatctl: repository busy\n")
                exit(EX_TEMPFAIL)
            }
            if TravelCLIErrorPolicy.isSilentSuccess(error) {
                if Array(CommandLine.arguments.dropFirst()) == [TravelCLICommand.validateCandidate.rawValue] {
                    // No snapshot was safely loaded. -1 is the documented unavailable-version sentinel.
                    try? writeJSON(ValidationResult(
                        valid: false,
                        violations: ["repositoryBusy"],
                        stateVersion: -1,
                        publishEnvelope: nil
                    ))
                    exit(EX_TEMPFAIL)
                }
                exit(0)
            }
            writeStandardError("travelcatctl: \(error)\n")
            exit(65)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command: TravelCLICommand
        do {
            command = try TravelCLICommand.parse(arguments: arguments)
        } catch {
            writeStandardError(usage)
            exit(64)
        }

        if command == .installDefaultPet {
            let environment = ProcessInfo.processInfo.environment
            guard let resources = absoluteURL(environment["TRAVEL_CAT_DEFAULT_PET_RESOURCES_ROOT"]),
                  let pets = absoluteURL(environment["TRAVEL_CAT_DEFAULT_PETS_ROOT"]) else {
                throw DefaultPetInstallerError.invalidPath
            }
            try writeJSON(DefaultPetInstaller(resourcesRoot: resources, petsRoot: pets).install())
            return
        }

        let configuration = try TravelCLIConfiguration(
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let characterRequest = command == .configureCharacter
            ? try CharacterConfigurationRequest.decode(readStandardInput(maximumBytes: 64 * 1_024))
            : nil
        let preparationRequest = command == .preparePostcard
            ? try PostcardPreparationRequest.decode(readStandardInput(maximumBytes: 65_536))
            : nil

        let repository = try TravelRepository(root: configuration.root, clock: FixedClock(now: configuration.now))

        switch command {
        case .status:
            try writeJSON(repository.loadSnapshot())
        case .journal:
            let contents = try repository.loadContents()
            try writeJSON(TravelJournalProjection.make(contents: contents, now: configuration.now)
                .enriched(runtime: configuration.runtime))
        case .claim:
            let claim = try repository.claimDue(mode: configuration.resolvedMode(), now: configuration.now)
            try writeJSON(claim.enriched(runtime: configuration.runtime))
        case .publish:
            let envelope = try JSONDecoder.travelCat.decode(
                PublishEnvelope.self,
                from: FileHandle.standardInput.readDataToEndOfFile()
            )
            let acknowledgedVersion = try repository.publish(
                event: envelope.event,
                next: envelope.next
            )
            try writeJSON(PublishAcknowledgement(
                eventID: envelope.event.id,
                stateVersion: acknowledgedVersion
            ))
        case .pendingImages:
            let work = try repository.pendingImages(mode: try configuration.resolvedMode())
            try writeJSON(work.map { $0.enriched(runtime: configuration.runtime) })
        case .markImage:
            let envelope = try ImageResultEnvelope.decode(readStandardInput())
            try writeJSON(repository.markImage(envelope, mode: try configuration.resolvedMode()))
        case .preparePostcard:
            guard let preparationRequest else { throw CharacterConfigurationRequestError.invalidRequest }
            try writeJSON(PostcardPreparation(repository: repository).execute(preparationRequest))
        case .validateCandidate:
            let contents = try repository.loadContents()
            let snapshot = contents.snapshot
            let candidate: AgentEventEnvelope
            do {
                let data = try readStandardInput()
                candidate = try AgentEventEnvelope.decode(data)
            } catch let AgentEnvelopeError.structural(violations) {
                try writeJSON(ValidationResult(
                    valid: false,
                    violations: violations,
                    stateVersion: snapshot.stateVersion,
                    publishEnvelope: nil
                ))
                exit(65)
            }
            var calendar = Calendar.current
            calendar.timeZone = .current
            let result = candidate.validationResult(
                previous: snapshot,
                existingEventIDs: Set(contents.events.map(\.id)),
                mode: try configuration.resolvedMode(),
                calendar: calendar,
                now: configuration.now
            )
            try writeJSON(result)
            if !result.valid { exit(66) }
        case .character:
            try writeJSON(repository.characterConfiguration())
        case .configureCharacter:
            try writeJSON(repository.configureCharacter(try requireCharacterRequest(characterRequest)))
        case .installDefaultPet:
            preconditionFailure("install-default-pet is handled before repository construction")
        }
    }

    private static func absoluteURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func requireCharacterRequest(
        _ request: CharacterConfigurationRequest?
    ) throws -> CharacterConfigurationRequest {
        guard let request else { throw CharacterConfigurationRequestError.invalidRequest }
        return request
    }

    private static func writeJSON<Value: Encodable>(_ value: Value) throws {
        var data = try JSONEncoder.travelCat.encode(value)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func readStandardInput(maximumBytes: Int = 1_048_576) throws -> Data {
        var result = Data()
        while true {
            let remaining = maximumBytes + 1 - result.count
            guard remaining > 0 else { throw AgentEnvelopeError.structural(["tooLarge"]) }
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, remaining)),
                  !chunk.isEmpty else { return result }
            result.append(chunk)
            if result.count > maximumBytes { throw AgentEnvelopeError.structural(["tooLarge"]) }
        }
    }

    private static func writeStandardError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
}
