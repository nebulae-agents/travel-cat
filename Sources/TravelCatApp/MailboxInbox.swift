import AppKit

struct MailboxEntry: Identifiable, Equatable {
    enum Kind: Int { case approval, failure, result, postcard }
    enum Destination: Equatable { case task(UUID), postcard(UUID) }
    let id: String
    let title: String
    let subtitle: String
    let date: Date
    let kind: Kind
    let destination: Destination
    static func postcard(id: UUID, date: Date) -> Self {
        .init(id: "postcard-\(id)", title: "小黑寄来了一张明信片", subtitle: "远方来信 · 打开后阅读", date: date, kind: .postcard, destination: .postcard(id))
    }
    var symbol: String {
        switch kind { case .approval: "hand.raised.fill"; case .failure: "exclamationmark.triangle.fill"; case .result: "checkmark.seal.fill"; case .postcard: "envelope.fill" }
    }
}

/// Read-only projection: opening the inbox never changes read state or grants permission.
struct MailboxInbox {
    let entries: [MailboxEntry]
    var badge: String? { entries.isEmpty ? nil : entries.count > 99 ? "99+" : String(entries.count) }
    var singleEntry: MailboxEntry? { entries.count == 1 ? entries.first : nil }
    static func project(tasks: [WorkbenchTask], pendingTaskIDs: [UUID], postcards: [MailboxEntry]) -> Self {
        let pending = Set(pendingTaskIDs)
        var entries = tasks.compactMap { task -> MailboxEntry? in
            let kind: MailboxEntry.Kind
            let subtitle: String
            if pending.contains(task.id) { kind = .approval; subtitle = "等待你确认 · 查看后再决定" }
            else if task.unread && !task.status.active {
                kind = [.failed, .unknown].contains(task.status) ? .failure : .result
                subtitle = "Agent · \(task.status.title)"
            } else { return nil }
            return .init(id: "task-\(task.id)", title: task.title, subtitle: subtitle, date: task.createdAt, kind: kind, destination: .task(task.id))
        }
        entries += postcards
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.id).inserted }.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
        return .init(entries: entries)
    }
}

enum MailboxPlacement {
    static let size = CGSize(width: 78, height: 104)
    static func frame(beside house: CGRect, screens: [CGRect], offset: CGPoint? = nil) -> CGRect {
        let screen = screens.max { a, b in
            let aRect = a.intersection(house), bRect = b.intersection(house)
            return (aRect.isNull ? 0 : aRect.width * aRect.height) < (bRect.isNull ? 0 : bRect.width * bRect.height)
        }
        var x = house.maxX + 2
        if let screen, x + size.width > screen.maxX { x = house.minX - size.width - 2 }
        var result = CGRect(origin: offset.map { CGPoint(x: house.minX + $0.x, y: house.minY + $0.y) } ?? CGPoint(x: x, y: house.minY + 48), size: size)
        if let screen {
            result.origin.x = max(screen.minX, min(result.minX, screen.maxX - result.width))
            result.origin.y = max(screen.minY, min(result.minY, screen.maxY - result.height))
        }
        return result
    }
    static func inboxFrame(beside mailbox: CGRect, size: CGSize, screens: [CGRect], offset: CGPoint? = nil) -> CGRect {
        var screen = screens.max { a, b in
            let ar = a.intersection(mailbox), br = b.intersection(mailbox)
            return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
        }
        var origin = CGPoint(x: mailbox.midX - size.width / 2, y: mailbox.maxY + 8)
        if let offset { origin = CGPoint(x: mailbox.minX + offset.x, y: mailbox.minY + offset.y) }
        else if let screen, origin.y + size.height > screen.maxY { origin.y = mailbox.minY - size.height - 8 }
        var frame = CGRect(origin: origin, size: size)
        if offset != nil {
            screen = screens.max { lhs, rhs in
                let left = lhs.intersection(frame), right = rhs.intersection(frame)
                let leftArea = left.isNull ? 0 : left.width * left.height
                let rightArea = right.isNull ? 0 : right.width * right.height
                if leftArea != rightArea { return leftArea < rightArea }
                return hypot(lhs.midX - frame.midX, lhs.midY - frame.midY) > hypot(rhs.midX - frame.midX, rhs.midY - frame.midY)
            }
        }
        if let screen {
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        }
        return frame
    }

}

@MainActor
final class MailboxPositionStore {
    private let defaults: UserDefaults
    private let key = "travel-cat.mailbox-relative-origin"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var offset: CGPoint? { read(key) }
    var inboxOffset: CGPoint? { read(key + ".inbox") }
    private func read(_ key: String) -> CGPoint? {
        guard let pair = defaults.array(forKey: key) as? [Double], pair.count == 2,
              pair.allSatisfy({ $0.isFinite }) else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }
    func save(_ offset: CGPoint) { save(offset, key: key) }
    func saveInbox(_ offset: CGPoint) { save(offset, key: key + ".inbox") }
    private func save(_ offset: CGPoint, key: String) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        defaults.set([Double(offset.x), Double(offset.y)], forKey: key)
    }
}
