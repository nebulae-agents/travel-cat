import Foundation

@MainActor
extension AgentWorkbenchModel {
    func draft(for target: WorkbenchDraftTarget) -> WorkbenchSubmissionDraft {
        state.drafts?.draft(for: target) ?? WorkbenchSubmissionDraft()
    }
    func updateDraft(_ target: WorkbenchDraftTarget, _ change: (inout WorkbenchSubmissionDraft) -> Void) {
        // Never queue placeholder content while encrypted storage is still opening.
        guard isStorageReady else { return }
        var drafts = state.drafts ?? WorkbenchDraftCollection()
        drafts.update(target, change); state.drafts = drafts
        draftsDirty = true
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }
    func removeDraftParent(_ target: WorkbenchDraftTarget) {
        guard draft(for: target).parentTaskID != nil else { return }
        updateDraft(target) { $0.parentTaskID = nil }
    }
    func retryDraftSave() { persist() }
    func clearDraft(_ target: WorkbenchDraftTarget, submittedRevision: UUID) {
        guard isStorageReady, draft(for: target).revision == submittedRevision else { return }
        state.drafts?.clear(target, submittedRevision: submittedRevision)
        draftsDirty = true
        persist()
    }
    func isDraftSubmitting(_ target: WorkbenchDraftTarget) -> Bool {
        submittingDrafts[target]?.contains(draft(for: target).revision) == true
    }
    func startDraft(target: WorkbenchDraftTarget, instanceID: UUID, modelPolicy: String = "review", onSubmitted: (@MainActor () -> Void)? = nil) async {
        guard isStorageReady, !isStarting, !isDraftSubmitting(target) else { return }
        let submitted = draft(for: target)
        guard !submitted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submittingDrafts[target, default: []].insert(submitted.revision)
        defer {
            submittingDrafts[target]?.remove(submitted.revision)
            if submittingDrafts[target]?.isEmpty == true { submittingDrafts.removeValue(forKey: target) }
        }
        await start(instanceID: instanceID, text: submitted.text, files: submitted.files,
                    parentTaskID: submitted.parentTaskID, modelPolicy: modelPolicy) { [weak self] in
            self?.clearDraft(target, submittedRevision: submitted.revision)
            onSubmitted?()
        }
    }
    func followUpDraft(taskID: UUID) async {
        let target = WorkbenchDraftTarget.task(taskID)
        guard isStorageReady, !isDraftSubmitting(target) else { return }
        let submitted = draft(for: target)
        guard submitted.files.isEmpty else {
            error = "追问暂不支持输入文件，请先保留或移除文件；草稿已保留。"
            return
        }
        submittingDrafts[target, default: []].insert(submitted.revision)
        defer {
            submittingDrafts[target]?.remove(submitted.revision)
            if submittingDrafts[target]?.isEmpty == true { submittingDrafts.removeValue(forKey: target) }
        }
        if await followUp(taskID: taskID, text: submitted.text) {
            clearDraft(target, submittedRevision: submitted.revision)
        }
    }
}
