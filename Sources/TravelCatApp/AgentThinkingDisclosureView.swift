import SwiftUI

@MainActor struct AgentThinkingDisclosureView: View {
    let taskID: UUID
    let content: AgentThinkingContent
    @ObservedObject var expansion: AgentThinkingExpansion
    private var identity: AgentThinkingIdentity { .init(taskID: taskID, entryID: content.id) }
    private var isExpanded: Binding<Bool> {
        Binding(get: { expansion.isExpanded(identity) }, set: { expansion.setExpanded($0, for: identity) })
    }
    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            // Do not construct a reader or leave hidden raw/copy focus targets while collapsed.
            if isExpanded.wrappedValue {
                AgentMarkdownMessageView(text: content.text, rawSource: content.rawSource)
                    .padding(.top, 8)
            }
        } label: {
            Text("思考内容").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.muted)
        }
        .accessibilityIdentifier("thinking:" + taskID.uuidString + ":" + content.id)
        .id(identity)
    }
}
