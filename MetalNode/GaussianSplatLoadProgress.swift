import Foundation

struct GaussianSplatLoadStatus: Equatable {
    var isLoading: Bool = false
    var progress: Double = 0.0
    var message: String = "Idle"
}

final class GaussianSplatLoadProgressStore {
    static let shared = GaussianSplatLoadProgressStore()
    static let didChangeNotification = Notification.Name("GaussianSplatLoadProgressStore.didChange")

    private let lock = NSLock()
    private var statuses: [UUID: GaussianSplatLoadStatus] = [:]

    private init() {}

    func status(for nodeID: UUID) -> GaussianSplatLoadStatus {
        lock.lock()
        defer { lock.unlock() }
        return statuses[nodeID] ?? GaussianSplatLoadStatus()
    }

    func update(nodeID: UUID, isLoading: Bool, progress: Double, message: String) {
        let clampedProgress = min(max(progress, 0.0), 1.0)
        let status = GaussianSplatLoadStatus(
            isLoading: isLoading,
            progress: clampedProgress,
            message: message
        )

        lock.lock()
        let oldStatus = statuses[nodeID]
        statuses[nodeID] = status
        lock.unlock()

        guard oldStatus != status else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: ["nodeID": nodeID]
            )
        }
    }

    func remove(nodeID: UUID) {
        lock.lock()
        let removed = statuses.removeValue(forKey: nodeID) != nil
        lock.unlock()

        guard removed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: ["nodeID": nodeID]
            )
        }
    }
}
