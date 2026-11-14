import Foundation

enum AgentXAppArea: String, Codable { case frontend, backstage }
struct AgentXAppLocation: Equatable {
    var area: AgentXAppArea
    var page: AgentXPage
    var moduleID: String?
}
