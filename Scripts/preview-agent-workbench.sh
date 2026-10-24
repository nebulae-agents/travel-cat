#!/bin/zsh
set -euo pipefail
project_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
preview_root="${TRAVEL_CAT_PREVIEW_ROOT:-$(mktemp -d /tmp/travelcat-agent-preview.XXXXXX)}"
preview_name="${TRAVEL_CAT_PREVIEW_NAME:-AgentWorkbenchPreview}"
preview_app="$(python3 "$project_root/Scripts/prepare-agent-preview.py" --project-root "$project_root" --root "$preview_root" --name "$preview_name" --bundle-id "${TRAVEL_CAT_PREVIEW_BUNDLE_ID:-com.nebulae.travelcat.agent-preview}")"
# Build dependencies through the repository wrapper; all products stay outside the worktree.
build_args=(--build-system native)
if [[ -n "${TRAVEL_CAT_PREVIEW_SDK:-}" ]]; then build_args+=(--sdk "$TRAVEL_CAT_PREVIEW_SDK"); fi
"$project_root/Scripts/travel-cat-swift.sh" build "${build_args[@]}" --product TravelCatApp >&2
sdk_args=()
if [[ -n "${TRAVEL_CAT_PREVIEW_SDK:-}" ]]; then sdk_args=(-sdk "$TRAVEL_CAT_PREVIEW_SDK"); fi
preview_scratch="$("$project_root/Scripts/travel-cat-swift.sh" scratch-path)"
# Link actual TravelUI positioning code and actual launcher into the isolated fixture.
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library "${sdk_args[@]}" \
  -I "$preview_scratch/debug/Modules" \
  "$preview_scratch"/debug/TravelUI.build/*.o \
  "$preview_scratch"/debug/TravelStorage.build/*.o \
  "$preview_scratch"/debug/TravelCore.build/*.o -lsqlite3 \
  "$project_root/Sources/TravelCatApp/PetCompanionLayout.swift" \
  "$project_root/Sources/TravelCatApp/CodexPetStateReader.swift" \
  "$project_root/Sources/TravelCatApp/CodexPetLocator.swift" \
  "$project_root/Sources/TravelCatApp/TravelUtilityWindowController.swift" \
  "$project_root/Sources/TravelCatApp/DesktopPetAnchorProvider.swift" \
  "$project_root/Sources/TravelCatApp/StandalonePetController.swift" \
  "$project_root/Sources/TravelCatApp/SingleInstancePolicy.swift" \
  "$project_root/Sources/TravelCatApp/WorkbenchReadReceipt.swift" \
  "$project_root/Sources/TravelCatApp/CottageTheme.swift" \
  "$project_root/Sources/TravelCatApp/MailboxInbox.swift" \
  "$project_root/Sources/TravelCatApp/MailboxViews.swift" \
  "$project_root/Sources/TravelCatApp/AgentLauncherController.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchData.swift" \
  "$project_root/Sources/TravelCatApp/AgentDraftData.swift" \
  "$project_root/Sources/TravelCatApp/NativeAgentData.swift" \
  "$project_root/Sources/TravelCatApp/NativeAgentSetupView.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel+Native.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel+Background.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel+Reconciliation.swift" \
  "$project_root/Sources/TravelCatApp/AgentSidecarClient.swift" \
  "$project_root/Sources/TravelCatApp/EncryptedWorkbenchStore.swift" \
  "$project_root/Sources/TravelCatApp/AgentAuditStorageView.swift" \
  "$project_root/Sources/TravelCatApp/AgentAuditStore.swift" \
  "$project_root/Sources/TravelCatApp/AgentCallInspector.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel+Storage.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel+Drafts.swift" \
  "$project_root/Sources/TravelCatApp/AgentRuntimeDiscovery.swift" \
  "$project_root/Sources/TravelCatApp/AgentQuickCreateView.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchPresentation.swift" \
  "$project_root/Sources/TravelCatApp/AgentConversationManagement.swift" \
  "$project_root/Sources/TravelCatApp/AgentConversationManagementView.swift" \
  "$project_root/Sources/TravelCatApp/AgentMessageEditor.swift" \
  "$project_root/Sources/TravelCatApp/AgentConversationDetailsView.swift" \
  "$project_root/Sources/TravelCatApp/AgentMarkdownContent.swift" \
  "$project_root/Sources/TravelCatApp/AgentMarkdownMessageView.swift" \
  "$project_root/Sources/TravelCatApp/AgentThinkingContent.swift" \
  "$project_root/Sources/TravelCatApp/AgentThinkingDisclosureView.swift" \
  "$project_root/Sources/TravelCatApp/AgentConversationView.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchSettingsView.swift" \
  "$project_root/Sources/TravelCatApp/AgentInstanceEditor.swift" \
  "$project_root/Sources/TravelCatApp/AgentArtifactData.swift" \
  "$project_root/Sources/TravelCatApp/AgentArtifactVersions.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchModel+Artifacts.swift" \
  "$project_root/Sources/TravelCatApp/AgentArtifactsView.swift" \
  "$project_root/Sources/TravelCatApp/AgentWorkbenchView.swift" \
  "$project_root/Sources/TravelCatApp/ServiceCredentialStore.swift" \
  "$project_root/Tests/ManualAgentWorkbench/${TRAVEL_CAT_PREVIEW_SOURCE:-Preview.swift}" \
  -o "$preview_app/Contents/MacOS/$preview_name"
print -r -- "$preview_app"
# Caller opens the printed app path. Native fixtures preserve their independent profile and ownership evidence.
