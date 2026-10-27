import Combine
import Foundation
import TravelStorage

@MainActor final class BackupExportController: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var cancellationRequested = false
    @Published private(set) var progress = RepositoryExportProgress()
    @Published private(set) var message: String?
    typealias Operation = @Sendable (URL, RepositoryExportControl) throws -> URL
    private let operation: Operation
    init(operation: @escaping Operation) { self.operation = operation }
    convenience init(repository: TravelRepository) { self.init { try repository.export(to: $0, control: $1) } }
    private var task: Task<Void, Never>?
    private var control: RepositoryExportControl?
    private var generation = UUID()
    @discardableResult func start(to destination: URL) -> Bool {
        guard task == nil else { return false }
        let token = UUID(); generation = token
        isExporting = true; cancellationRequested = false
        progress = .init(); message = nil
        let control = RepositoryExportControl(progress: { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == token, self.isExporting else { return }
                self.progress = value
            }
        })
        self.control = control
        let operation = operation
        let worker = Task.detached(priority: .utility) { try operation(destination, control) }
        // Own the worker until it settles, even after cancellation or view closure.
        task = Task { [weak self] in
            let result = await worker.result
            guard let self, generation == token else { return }
            switch result {
            case .success: message = "备份已导出。"
            case .failure(is CancellationError): message = "导出已取消，未发布备份；原始数据已保留。"
            case .failure(RepositoryError.unsafeExportDestination): message = "请将导出位置选在 Travel Cat 数据目录之外，再重试导出。"
            case .failure: message = "导出失败，请检查目标位置、可用空间和权限后重试；原始数据已保留。"
            }
            isExporting = false; self.control = nil; task = nil
        }
        return true
    }
    func cancel() {
        guard isExporting, !cancellationRequested else { return }
        if control?.cancel() == true { cancellationRequested = true }
        else { message = "备份正在完成，请稍候。" }
    }
    func waitForCompletion() async { await task?.value }
}
