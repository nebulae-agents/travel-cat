import Foundation
import Testing
import Yams
@testable import TravelCatApp

struct AgentXCharacterTests {
    @Test func preservesUnknownDataAndManualFilesAndExcludesDirectorSecrets() throws {
        let yaml = "identity:\n  name: 柳三娘\nbackground:\n  origin: 南方\n  secrets_director_only: [绝密暗号]\nrelations:\n  - {to: player, trust: 0}\ncustom: {keep: [one, two]}\n"
        let original = AgentXDefinitionDocument(source: "---\ncustom: untouched\n---\nManual instructions\n", files: ["character.yaml": yaml, "soul.md": "Manual soul\n", "memory/relations.json": "[{\"manual\":true}]", "extra.txt": "untouched"])
        var profile = try AgentXCharacterProfile.load(from: original)
        try profile.setText("说话温柔", for: .voice)
        let saved = try profile.applying(to: original)
        #expect(saved.source.hasPrefix(original.source))
        #expect(saved.files["extra.txt"] == "untouched")
        #expect(saved.files["soul.md"]?.hasPrefix("Manual soul\n") == true)
        #expect(saved.files["memory/relations.json"] == original.files["memory/relations.json"])
        let parsed = try Yams.load(yaml: #require(saved.files["character.yaml"])) as? [String: Any]
        #expect((parsed?["custom"] as? [String: [String]])?["keep"] == ["one", "two"])
        #expect((parsed?["background"] as? [String: Any])?["secrets_director_only"] as? [String] == ["绝密暗号"])
        #expect(try saved.executionPrompt().contains("说话温柔"))
        #expect(try !saved.executionPrompt().contains("绝密暗号"))
        #expect(try AgentXCharacterProfile.load(from: saved).text(for: .voice) == "说话温柔")
        #expect(try AgentXCharacterProfile.load(from: saved).applying(to: saved) == saved)
    }
    @Test func allDimensionsRoundTripAndRejectBrokenManagedBlocks() throws {
        var profile = AgentXCharacterProfile()
        #expect(AgentXCharacterDimension.allCases.count == 12)
        for dimension in AgentXCharacterDimension.allCases { try profile.setText("设定 \(dimension.rawValue)", for: dimension) }
        let saved = try profile.applying(to: .init(source: "Base"))
        let loaded = try AgentXCharacterProfile.load(from: saved)
        for dimension in AgentXCharacterDimension.allCases { #expect(loaded.text(for: dimension) == "设定 \(dimension.rawValue)") }
        #expect(try !saved.executionPrompt().contains("设定 model"))
        #expect(throws: (any Error).self) { try profile.applying(to: .init(source: "<!-- agentx-character:start -->broken")) }
        #expect(throws: (any Error).self) { try profile.setText("<!-- agentx-character:end -->", for: .voice) }
    }
    @Test func nestedDirectorValuesCannotLeakThroughPublicFields() throws {
        let yaml = """
        background:
          origin: public origin
          nested:
            secrets_director_only: [private passphrase]
        voice:
          sample: private passphrase
        """
        let original = AgentXDefinitionDocument(source: "Manual instructions", files: ["character.yaml": yaml])
        let profile = try AgentXCharacterProfile.load(from: original)
        let saved = try profile.applying(to: original)
        #expect(try saved.executionPrompt().contains("public origin"))
        #expect(try !saved.executionPrompt().contains("private passphrase"))
        #expect(saved.files["character.yaml"] == yaml)
    }
    @Test func rejectsImportedManagedMarkerInjection() throws {
        let original = AgentXDefinitionDocument(source: "Manual instructions", files: ["character.yaml": "voice: '<!-- agentx-character:end -->'\n"])
        let profile = try AgentXCharacterProfile.load(from: original)
        #expect(throws: (any Error).self) { try profile.applying(to: original) }
    }

}
