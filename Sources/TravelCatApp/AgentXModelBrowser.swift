import SwiftUI

/// Shared browser for conversation choices and editor drafts. Preference actions never choose a model.
@MainActor
struct AgentXModelBrowser: View {
    let providers: [AgentXProvider]
    var selected: AgentXConversationModel? = nil
    var busy = false
    var category: AgentXModelCategory = .chat
    var choose: ((AgentXModelBrowserEntry) throws -> Void)? = nil
    let favorite: (AgentXModelBrowserEntry) throws -> Void
    var enable: ((AgentXModelBrowserEntry, Bool) throws -> Void)? = nil
    var setDefault: ((AgentXModelBrowserEntry) throws -> Void)? = nil
    @State private var query = ""
    @State private var enabledOnly = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    private var favorites: [AgentXModelBrowserEntry] { AgentXModelBrowserQuery.favorites(providers: providers) }
    private var results: [AgentXModelBrowserEntry] {
        AgentXModelBrowserQuery.results(providers: providers, query: query).filter { !enabledOnly || $0.model.enabled }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索名称或 ID，如 ds v4.1 flash", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("搜索模型").focused($searchFocused)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if busy { Text("运行中不可切换模型，仍可管理收藏。").font(.caption).foregroundStyle(.orange) }
            HStack { Text("收藏（\(favorites.count)）").font(.headline); Spacer(); Text("星标只管理收藏").font(.caption).foregroundStyle(AgentXTheme.muted) }
            if favorites.isEmpty {
                Text("点击模型右侧星标加入收藏。").font(.caption).foregroundStyle(AgentXTheme.muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) { ForEach(favorites) { row($0, compact: true) } }.padding(.trailing, 5)
                }.frame(height: min(CGFloat(favorites.count) * 76, 180))
            }
            Divider()
            HStack {
                Text("模型目录（\(results.count)）").font(.headline)
                Spacer()
                Toggle("仅已启用", isOn: $enabledOnly).toggleStyle(.checkbox)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if results.isEmpty { Text("没有匹配的模型").foregroundStyle(AgentXTheme.muted) }
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(results) { row($0) }
                    } else {
                        ForEach(AgentXModelBrowserQuery.groups(results)) { group in
                            if providers.count == 1 { vendors(group) }
                            else {
                                DisclosureGroup { vendors(group).padding(.leading, 10) } label: { Text(group.name).font(.headline) }
                            }
                        }
                    }
                }.padding(.trailing, 5)
            }.frame(minHeight: 150)
        }.onAppear { searchFocused = true }
    }
    private func vendors(_ group: AgentXModelBrowserGroup) -> some View {
        ForEach(group.vendors) { vendor in
            DisclosureGroup {
                LazyVStack(alignment: .leading, spacing: 12) { ForEach(vendor.entries) { row($0) } }.padding(.leading, 10)
            } label: { Text("\(vendor.id)（\(vendor.entries.count)）").font(.subheadline.bold()) }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func row(_ entry: AgentXModelBrowserEntry, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.model.name ?? entry.model.id).font(.body.weight(.medium)).lineLimit(2)
                        if let variant = entry.variantLabel { Text(variant).font(.caption.bold()).foregroundStyle(.orange) }
                        if providers.first(where: { $0.id == entry.providerID })?.modelSelection?.defaultModel(for: category) == entry.model.id {
                            Text("默认").font(.caption.bold()).foregroundStyle(AgentXTheme.accent)
                        }
                    }
                    Text("\(entry.providerName) · \(entry.model.id)").font(.caption).foregroundStyle(AgentXTheme.muted).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let choose {
                    Button(selected == entry.choice ? "当前模型" : "选择") { perform { try choose(entry) } }
                        .disabled(busy || entry.disabledReason() != nil)
                        .accessibilityLabel("选择模型 \(entry.providerName) \(entry.model.id)")
                }
                if let setDefault {
                    Button("设为默认") { perform { try setDefault(entry) } }
                        .disabled(entry.disabledReason(requiresEnabled: false, category: category) != nil)
                        .accessibilityLabel("设为默认 \(entry.model.id)")
                }
                Button { perform { try favorite(entry) } } label: {
                    Image(systemName: entry.model.favorite ? "star.fill" : "star").foregroundStyle(entry.model.favorite ? .yellow : AgentXTheme.muted)
                }.buttonStyle(.borderless).accessibilityLabel("\(entry.model.favorite ? "取消收藏" : "收藏模型") \(entry.providerName) \(entry.model.id)")
            }
            if !compact {
                if let enable {
                    Toggle("启用模型", isOn: Binding(get: { entry.model.enabled }, set: { value in perform { try enable(entry, value) } }))
                        .toggleStyle(.checkbox).disabled(!entry.model.available && !entry.model.enabled)
                        .accessibilityLabel("启用模型 \(entry.model.id)")
                }
                AgentXCatalogModelDetails(model: entry.model)
            }
            if let reason = entry.disabledReason(requiresEnabled: choose != nil, category: category) {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
        }.padding(8).background(selected == entry.choice ? AgentXTheme.accent.opacity(0.12) : Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
