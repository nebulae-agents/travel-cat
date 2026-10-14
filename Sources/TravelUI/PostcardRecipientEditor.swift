import SwiftUI

@MainActor
public struct PostcardRecipientSettingsView: View {
    @ObservedObject private var model: AppModel
    @State private var isEditing = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Button { isEditing = true } label: {
            Label("收件信息", systemImage: "person.crop.rectangle")
        }
        .sheet(isPresented: $isEditing) { PostcardRecipientEditor(model: model) }
    }
}

@MainActor
private struct PostcardRecipientEditor: View {
    @ObservedObject var model: AppModel
    @State private var draft: PostcardRecipientInfo
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.postcardRecipient)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("明信片收件信息").font(.title2.weight(.medium))
            Form {
                TextField("收件人", text: $draft.name)
                TextField("收件地址", text: $draft.address, axis: .vertical).lineLimit(2...4)
                TextField("邮编", text: $draft.postalCode)
            }
            Text("仅保存在本机，用于明信片显示。地址和邮编可留空。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    model.savePostcardRecipient(draft)
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
