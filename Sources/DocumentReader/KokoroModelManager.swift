import CryptoKit
import Foundation

struct KokoroModelManifest: Codable, Sendable {
    struct Asset: Codable, Sendable {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    let version: String
    let displayName: String
    let assets: [Asset]

    static func bundled() throws -> KokoroModelManifest {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("DocumentReader_DocumentReader.bundle") }
            .flatMap(Bundle.init(url:))
        guard let url = (packagedBundle ?? Bundle.module)
            .url(forResource: "kokoro-model", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@MainActor
final class KokoroModelManager: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading
        case verifying
        case ready
        case failed(String)
    }

    static let shared = KokoroModelManager()

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = ""

    let manifest: KokoroModelManifest
    private var installTask: Task<Void, Never>?
    private var downloader: FileDownloader?

    var installedDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("Kokoro", isDirectory: true)
            .appendingPathComponent(manifest.version, isDirectory: true)
    }

    var modelURL: URL {
        installedDirectory.appendingPathComponent("kokoro-v1_0.safetensors")
    }

    var voicesURL: URL {
        installedDirectory.appendingPathComponent("voices.npz")
    }

    init(manifest: KokoroModelManifest? = nil) {
        self.manifest = manifest ?? (try! .bundled())
        refreshState()
    }

    func refreshState() {
        state = assetsExist() ? .ready : .notInstalled
    }

    func install() {
        guard state != .downloading && state != .verifying else { return }
        installTask?.cancel()
        progress = 0
        state = .downloading
        statusMessage = "Preparing download…"

        installTask = Task {
            do {
                try ensureAvailableStorage()
                let fileManager = FileManager.default
                let staging = applicationSupportDirectory
                    .appendingPathComponent("Kokoro.installing", isDirectory: true)
                try? fileManager.removeItem(at: staging)
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

                let total = manifest.assets.reduce(Int64(0)) { $0 + $1.size }
                var completed: Int64 = 0
                for asset in manifest.assets {
                    try Task.checkCancellation()
                    let target = staging.appendingPathComponent(asset.name)
                    let completedBeforeAsset = completed
                    let operation = FileDownloader(
                        source: asset.url,
                        destination: target
                    ) { [weak self] written, _ in
                        Task { @MainActor in
                            self?.progress = min(
                                0.9,
                                Double(completedBeforeAsset + written) / Double(total) * 0.9
                            )
                            self?.statusMessage = "Downloading \(asset.name)…"
                        }
                    }
                    downloader = operation
                    try await operation.start()
                    completed += asset.size

                    state = .verifying
                    statusMessage = "Verifying \(asset.name)…"
                    let valid = try await KokoroAssetVerifier.verify(asset: asset, at: target)
                    guard valid else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    state = .downloading
                }

                try Task.checkCancellation()
                let parent = installedDirectory.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: installedDirectory)
                try fileManager.moveItem(at: staging, to: installedDirectory)
                removeOtherVersions()
                progress = 1
                statusMessage = "Enhanced Voice is ready."
                state = .ready
            } catch is CancellationError {
                cleanupStaging()
                state = .notInstalled
                statusMessage = "Download cancelled."
            } catch {
                cleanupStaging()
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
            downloader = nil
        }
    }

    func cancelInstall() {
        downloader?.cancel()
        installTask?.cancel()
        cleanupStaging()
        state = .notInstalled
        statusMessage = "Download cancelled."
    }

    func uninstall() {
        cancelInstall()
        try? FileManager.default.removeItem(
            at: installedDirectory.deletingLastPathComponent()
        )
        progress = 0
        statusMessage = "Enhanced Voice removed."
        state = .notInstalled
    }

    private var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocumentReader", isDirectory: true)
    }

    private func assetsExist() -> Bool {
        manifest.assets.allSatisfy {
            let url = installedDirectory.appendingPathComponent($0.name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.int64Value == $0.size
        }
    }

    private func ensureAvailableStorage() throws {
        let required = manifest.assets.reduce(Int64(0)) { $0 + $1.size } * 2
        let values = try applicationSupportDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < required {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private func cleanupStaging() {
        try? FileManager.default.removeItem(
            at: applicationSupportDirectory.appendingPathComponent("Kokoro.installing")
        )
    }

    private func removeOtherVersions() {
        let root = installedDirectory.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for child in children where child != installedDirectory {
            try? FileManager.default.removeItem(at: child)
        }
    }
}

enum KokoroAssetVerifier {
    nonisolated static func verify(
        asset: KokoroModelManifest.Asset,
        at url: URL
    ) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == asset.size else {
                return false
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
        }.value
    }
}

private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<Void, Error>?

    init(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.source = source
        self.destination = destination
        self.progress = progress
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: source)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        } else {
            finish(result ?? .failure(URLError(.cannotCreateFile)))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
