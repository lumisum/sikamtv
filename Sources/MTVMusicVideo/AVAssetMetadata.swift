import AVFoundation
import Foundation

/// Bridges AVFoundation's asynchronous metadata API into the existing render
/// and export queues. Callers already run away from the main actor, so loading
/// metadata here never stalls SwiftUI or frame presentation.
enum AVAssetMetadata {
    static func duration(of asset: AVAsset) -> CMTime? {
        let assetBox = Transfer(asset)
        return wait { Transfer(try await assetBox.value.load(.duration)) }?.value
    }

    static func tracks(in asset: AVAsset, mediaType: AVMediaType) -> [AVAssetTrack] {
        let assetBox = Transfer(asset)
        return wait { Transfer(try await assetBox.value.loadTracks(withMediaType: mediaType)) }?.value ?? []
    }

    static func preferredTransform(of track: AVAssetTrack) -> CGAffineTransform {
        let trackBox = Transfer(track)
        return wait { Transfer(try await trackBox.value.load(.preferredTransform)) }?.value ?? .identity
    }

    private static func wait<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> Value? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Value>()
        Task.detached(priority: .userInitiated) {
            box.store(try? await operation())
            semaphore.signal()
        }
        semaphore.wait()
        return box.load()
    }

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func store(_ value: Value?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// AVFoundation metadata objects are immutable for these reads, but the SDK
    /// has not annotated AVAsset/AVAssetTrack as Sendable. Keep that unchecked
    /// boundary local instead of weakening concurrency checks project-wide.
    private final class Transfer<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}
