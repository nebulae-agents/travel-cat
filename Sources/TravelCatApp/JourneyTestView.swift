import SwiftUI
import TravelUI

struct JourneyTestView: View {
    @ObservedObject var controller: JourneyTestController
    var closeWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("测试旅程").font(.headline)
                    Text(controller.status).font(.subheadline)
                    Text("仅保存在测试区域，不会加入正式旅行册。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isRunning {
                    ProgressView().controlSize(.small)
                    Button("停止测试") { controller.stop() }
                }
                if let model = controller.model {
                    Button("测试旅行册") { model.openLatestAlbumFromMenu() }
                }
            }
            .padding()
            if let error = controller.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal)
            }
            Divider()
            if let model = controller.model {
                MenuServiceRootView(model: model, closeWindow: closeWindow, presentationChanged: { _ in })
                    .id(controller.session?.id)
            } else {
                ContentUnavailableView("尚无测试旅程", systemImage: "pawprint", description: Text("在快速测试设置中开始一次完整旅程。"))
            }
        }
    }
}
