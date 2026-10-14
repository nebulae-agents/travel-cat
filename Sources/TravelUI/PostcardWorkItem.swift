import Foundation
import TravelCore
import TravelStorage

public enum PostcardWorkStatus: Equatable, Sendable {
    case pending, generating, manualRequired, damaged, ready

    public var label: String {
        switch self {
        case .pending: "等待生成"
        case .generating: "正在生成"
        case .manualRequired: "自动尝试 3 次后已停止；点击重试仅手动尝试一次。"
        case .damaged: "照片文件缺失或损坏；可手动重新生成一次。"
        case .ready: "已生成"
        }
    }
}

public struct PostcardWorkItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let tripID: UUID
    public let eventID: UUID?
    public let isSupplement: Bool
    public let generatedAt: Date?
    public let status: PostcardWorkStatus
    public let failureReason: String?
    public let isManualQueued: Bool

    public var statusLabel: String {
        if status == .manualRequired, failureReason?.hasPrefix("恢复安全副本") == true {
            return "恢复后等待手动处理；上次生成结果未知。"
        }
        if status == .pending {
            if eventID == nil { return "等待生成文字" }
            if isManualQueued { return "手动重试已排队" }
            return "等待生成图片"
        }
        return status.label
    }

    public init(id: UUID, tripID: UUID, eventID: UUID?, isSupplement: Bool, generatedAt: Date?, status: PostcardWorkStatus, failureReason: String? = nil, isManualQueued: Bool = false) {
        self.id = id
        self.tripID = tripID
        self.eventID = eventID
        self.isSupplement = isSupplement
        self.generatedAt = generatedAt
        self.status = status
        self.failureReason = failureReason
        self.isManualQueued = isManualQueued
    }
}

public enum PostcardWorkProjection {
    public static func items(plans: [PostcardBacklogPlan], retries: [UUID: ImageRetry], now: Date, damagedImageIDs: Set<UUID> = []) -> [PostcardWorkItem] {
        plans.flatMap { plan in
            plan.slots.map { slot in
                let retry = retries[slot.eventID ?? slot.id]
                let status: PostcardWorkStatus
                if let id = slot.eventID, damagedImageIDs.contains(id) {
                    status = .damaged
                } else if slot.imageReady {
                    status = .ready
                } else if slot.event?.postcardStatus == .imageUnavailable || retry?.terminalStatus == .imageUnavailable {
                    status = .manualRequired
                } else if retry?.activeAttemptToken != nil, let expires = retry?.leaseExpiresAt, expires > now {
                    status = .generating
                } else {
                    status = .pending
                }
                return PostcardWorkItem(id: slot.id, tripID: plan.tripID, eventID: slot.eventID,
                    isSupplement: slot.isSupplement, generatedAt: slot.event?.occurredAt,
                    status: status, failureReason: retry?.lastFailureReason,
                    isManualQueued: status == .pending && !(retry?.manualRequests.isEmpty ?? true))
            }
        }
    }
}
