import Foundation
import TravelCore
import TravelStorage

enum JourneyTestLocalContent {
  static func candidate(
    stage: TravelPhase, tripID: UUID, contents: RepositoryContents, now: Date
  ) -> AgentEventEnvelope {
    let location: Location? = switch stage {
    case .exploring: Location(country: "中国", city: "杭州", place: "苏堤春晓")
    case .postcardReady: Location(country: "中国", city: "杭州", place: "曲院风荷")
    default: nil
    }
    let summary: String = switch stage {
    case .preparing: "小黑猫收好随身小包，准备去杭州园林走一段安静的测试旅程。"
    case .transit: "小黑猫坐上前往杭州的列车，窗外的树影一路陪它靠近园林。"
    case .exploring: "小黑猫沿着苏堤春晓慢慢前行，在杭州西湖边观察树影与水面。"
    case .postcardReady: "小黑猫来到曲院风荷，在园林水岸停下脚步并认真留下明信片。"
    case .returning: "小黑猫告别杭州园林，带着水岸与花木的记忆踏上返程。"
    case .resting: "小黑猫平安回到家里，把杭州园林的见闻收好后舒服地休息。"
    }
    return AgentEventEnvelope(
      eventId: UUID(), tripId: tripID, previousEventId: contents.snapshot.lastEventID,
      occurredAt: now, phase: stage, location: location,
      transport: stage == .transit ? "列车" : nil, summary: summary,
      mood: contents.snapshot.mood,
      continuityReferences: ["延续杭州园林测试旅程的上一段经历"],
      openHook: nil, consumedItemId: nil,
      postcard: PostcardRequest(
        required: stage == .postcardReady,
        scenePrompt: stage == .postcardReady ? "黑猫在杭州园林水岸散步，旅行明信片，避免文字" : nil)
    )
  }
}
