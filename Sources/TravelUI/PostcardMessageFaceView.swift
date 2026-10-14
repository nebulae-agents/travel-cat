import SwiftUI
import TravelCore

/// The message and postal side of a postcard. The complete travel story stays outside the card.
public struct PostcardMessageFaceView: View {
    public static let aspectRatio: CGFloat = 1.5

    public let event: TripEvent
    public let recipient: PostcardRecipientInfo
    public let travelDate: Date?
    public let isUnread: Bool
    public let homeLocation: HomeLocation?

    public init(event: TripEvent, recipient: PostcardRecipientInfo = .empty,
                travelDate: Date? = nil, isUnread: Bool = true, homeLocation: HomeLocation? = nil) {
        self.event = event
        self.recipient = recipient.normalized
        self.travelDate = travelDate == TripAlbumChronology.unknownDate ? nil : travelDate
        self.isUnread = isUnread
        self.homeLocation = homeLocation
    }

    private let ink = Color(red: 0.29, green: 0.29, blue: 0.26)

    private var region: String {
        guard let location = event.location else { return "" }
        return [location.country, location.city].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var place: String {
        event.location?.place.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var spokenLocation: String { PostcardDisplayLocation().resolveSpoken(event.location) }

    var completeAccessibilityLabel: String {
        let date = travelDate.map(Self.postmarkDate) ?? "旅行日期待确认"
        let address = recipient.address.isEmpty ? "地址待填写" : recipient.address
        let postalCode = recipient.postalCode.isEmpty ? "邮编待填写" : "邮编 \(recipient.postalCode)"
        return "\(isUnread ? "未读明信片" : "明信片文字面")，寄语：\(event.mood.quote)，寄件人小黑，寄自\(spokenLocation)，\(date)，收件人\(recipient.name)，\(address)，\(postalCode)，\(PostcardPostage.resolve(location: event.location, home: homeLocation).accessibilityDescription)，翻看风景"
    }

    public var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 320
            let padding = 16 * scale
            let innerWidth = proxy.size.width - padding * 2
            let gap = 20 * scale
            let leftWidth = (innerWidth - gap) * 0.54
            let rightWidth = innerWidth - leftWidth - gap
            HStack(alignment: .top, spacing: 0) {
                message(scale: scale)
                    .frame(width: leftWidth, height: proxy.size.height - padding * 2)
                Rectangle().fill(ink.opacity(0.12))
                    .frame(width: 0.5 * scale, height: (proxy.size.height - padding * 2) * 0.86)
                    .frame(height: proxy.size.height - padding * 2, alignment: .bottom)
                    .padding(.horizontal, (gap - 0.5 * scale) / 2)
                postalInformation(scale: scale, width: rightWidth)
                    .frame(width: rightWidth, height: proxy.size.height - padding * 2, alignment: .topLeading)
            }
            .padding(padding)
        }
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [Color(red: 0.99, green: 0.985, blue: 0.965),
                                            Color(red: 0.975, green: 0.966, blue: 0.935)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ink.opacity(0.10), lineWidth: 0.5))
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .compositingGroup()
        .shadow(color: .black.opacity(0.09), radius: 4, x: 0, y: 2)
        .help(completeAccessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(completeAccessibilityLabel)
    }

    private func message(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("POST CARD")
                .font(.system(size: 6.8 * scale, weight: .regular, design: .serif))
                .tracking(1.8 * scale)
                .foregroundStyle(ink.opacity(0.48))
                .padding(.bottom, 19 * scale)
            Text(event.mood.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "寄语待补充" : PostcardVisualMessage.resolve(event.mood.quote))
                .font(handwritingFont(size: 12.5 * scale))
                .tracking(0.2 * scale)
                .lineSpacing(3.5 * scale)
                .lineLimit(4)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: 65 * scale, alignment: .topLeading)
            Spacer(minLength: 12 * scale)
            HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                postalRole("From", scale: scale)
                Text("小黑").font(handwritingFont(size: 12.5 * scale))
            }
            VStack(alignment: .leading, spacing: 2 * scale) {
                if !region.isEmpty {
                    Text(region)
                        .font(.system(size: 8.8 * scale, weight: .regular))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(place.isEmpty ? (region.isEmpty ? "旅途中" : "地点待确认") : place)
                    .font(.system(size: (place.count > 30 ? 8.4 : 8.8) * scale))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(ink.opacity(0.62))
            .help(spokenLocation)
            .padding(.top, 5 * scale)
        }
    }

    private func postalInformation(scale: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                PostcardPostageView(postage: PostcardPostage.resolve(location: event.location, home: homeLocation),
                    travelDate: travelDate, scale: scale)
            }
            .frame(height: 54 * scale, alignment: .top)
            Spacer(minLength: 12 * scale)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    postalRole("To", scale: scale)
                    Text(recipient.name)
                        .font(handwritingFont(size: 14 * scale))
                        .tracking(0.3 * scale)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                addressLines(scale: scale)
                    .padding(.top, 10 * scale)
                postalCode(scale: scale, width: width)
                    .frame(height: 14 * scale, alignment: .leading)
                    .padding(.top, 8 * scale)
            }
        }
    }

    private func postalRole(_ role: String, scale: CGFloat) -> some View {
        Text(role)
            .font(.system(size: 8 * scale, weight: .bold))
            .tracking(0.2 * scale)
            .foregroundStyle(ink.opacity(0.95))
            .fixedSize()
    }

    private func postalCode(scale: CGFloat, width: CGFloat) -> some View {
        let characters: [Character] = recipient.postalCode.isEmpty
            ? Array(repeating: " ", count: 6) : Array(recipient.postalCode)
        let isSeparator: (Character) -> Bool = {
            !recipient.postalCode.isEmpty && ($0.isWhitespace || $0 == "-")
        }
        let naturalWidth = characters.reduce(CGFloat.zero) { total, character in
            total + (isSeparator(character) ? 5 : 14)
        } + CGFloat(max(0, characters.count - 1)) * 2.5
        let cellScale = scale * min(1, width / (naturalWidth * scale))
        return HStack(spacing: 2.5 * cellScale) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                if isSeparator(character) {
                    Text(character.isWhitespace ? " " : String(character))
                        .frame(width: 5 * cellScale, height: 14 * cellScale)
                } else {
                    Text(String(character))
                        .frame(width: 14 * cellScale, height: 14 * cellScale)
                        .overlay(Rectangle().strokeBorder(
                            Color(red: 0.65, green: 0.39, blue: 0.32).opacity(0.62),
                            lineWidth: 0.65 * cellScale))
                }
            }
        }
        .font(.system(size: 10 * cellScale, weight: .medium, design: .monospaced))
        .foregroundStyle(ink.opacity(0.82))
    }

    private func addressLines(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 13 * scale) {
                ForEach(0..<3) { _ in
                    Rectangle().fill(ink.opacity(0.15)).frame(height: 0.5 * scale)
                }
            }
            .padding(.top, 12 * scale)
            if !recipient.address.isEmpty {
                Text(recipient.address)
                    .font(.system(size: 8.8 * scale, weight: .regular))
                    .foregroundStyle(ink.opacity(0.74))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .lineSpacing(2 * scale)
            }
        }
        .frame(height: 40 * scale, alignment: .topLeading)
        .help(recipient.address.isEmpty ? "地址待填写" : recipient.address)
    }

    private func handwritingFont(size: CGFloat) -> Font {
        let style = PostcardScenicTypography.handwriting()
        if let name = style.fontPostScriptName { return .custom(name, size: size) }
        return .system(size: size, design: .serif)
    }

    static func postmarkDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: date)
    }
}
