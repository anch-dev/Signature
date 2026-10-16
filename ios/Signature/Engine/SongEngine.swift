import AceEngine
import Foundation

enum GenStage: Int {
    case songwriter, diffusion, decode, saving

    var label: String {
        switch self {
        case .songwriter: return "Writing the song plan"
        case .diffusion: return "Generating audio"
        case .decode: return "Rendering"
        case .saving: return "Saving"
        }
    }

    /// Rough share of total time each stage takes, for one combined progress bar.
    var span: ClosedRange<Double> {
        switch self {
        case .songwriter: return 0.00...0.45
        case .diffusion: return 0.45...0.80
        case .decode: return 0.80...0.98
        case .saving: return 0.98...1.00
        }
    }
}

struct ModelPaths {
    var songwriter: URL?
    var textEncoder: URL
    var diffusion: URL
    var vae: URL
}

struct SongRequest {
    var caption: String
    var lyrics: String
    var language: String      // "" = auto
    var duration: Double
    var bpm: Int              // 0 = auto
    var seed: Int64           // -1 = random
    var adapter: URL?
    var adapterScale: Float
}

struct SongResult {
    var seed: Int64
    var bpm: Int
    var key: String
    var duration: Double
}

enum SongEngineError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The music engine could not start."
        case .failed(let msg): return msg
        }
    }
}

/// Owns the native engine. Generation runs on its own serial queue because a
/// song takes minutes of blocking Metal work.
final class SongEngine: @unchecked Sendable {
    static let shared = SongEngine()

    private let handle: OpaquePointer?
    private let queue = DispatchQueue(label: "signature.engine", qos: .userInitiated)

    private init() {
        handle = ace_engine_create()
    }

    deinit {
        ace_engine_free(handle)
    }

    private final class Box {
        let onProgress: (GenStage, Double) -> Void
        let isCancelled: () -> Bool
        init(onProgress: @escaping (GenStage, Double) -> Void, isCancelled: @escaping () -> Bool) {
            self.onProgress = onProgress
            self.isCancelled = isCancelled
        }
    }

    /// Returns nil when cancelled.
    func generate(
        _ request: SongRequest,
        models: ModelPaths,
        output: URL,
        onProgress: @escaping (GenStage, Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> SongResult? {
        guard let handle else { throw SongEngineError.unavailable }

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let box = Box(onProgress: onProgress, isCancelled: isCancelled)
                let user = Unmanaged.passRetained(box).toOpaque()
                defer { Unmanaged<Box>.fromOpaque(user).release() }

                let callback: ace_progress_fn = { user, stage, fraction in
                    guard let user else { return 0 }
                    let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                    let s = GenStage(rawValue: Int(stage.rawValue)) ?? .diffusion
                    let overall = s.span.lowerBound + Double(fraction) * (s.span.upperBound - s.span.lowerBound)
                    box.onProgress(s, overall)
                    return box.isCancelled() ? 1 : 0
                }

                // Keep every C string alive for the whole call.
                var owned: [UnsafeMutablePointer<CChar>] = []
                func c(_ s: String?) -> UnsafePointer<CChar>? {
                    guard let s, !s.isEmpty, let p = strdup(s) else { return nil }
                    owned.append(p)
                    return UnsafePointer(p)
                }
                defer { owned.forEach { free($0) } }

                var paths = ace_model_paths(
                    lm_path: c(models.songwriter?.path),
                    text_enc_path: c(models.textEncoder.path),
                    dit_path: c(models.diffusion.path),
                    vae_path: c(models.vae.path),
                    adapter_path: c(request.adapter?.path),
                    adapter_scale: request.adapterScale
                )
                var req = ace_song_request(
                    caption: c(request.caption),
                    lyrics: c(request.lyrics),
                    vocal_language: c(request.language),
                    duration: Float(request.duration),
                    bpm: Int32(request.bpm),
                    seed: request.seed,
                    inference_steps: 0
                )
                var info = ace_song_info()
                var err = [CChar](repeating: 0, count: 512)

                let rc = ace_engine_generate(
                    handle, &paths, &req, c(output.path), callback, user, &info, &err, Int32(err.count)
                )

                switch rc {
                case 0:
                    let key = withUnsafeBytes(of: info.keyscale) { raw in
                        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                    }
                    cont.resume(returning: SongResult(
                        seed: info.seed_used, bpm: Int(info.bpm), key: key, duration: Double(info.duration)))
                case 1:
                    cont.resume(returning: nil)
                default:
                    cont.resume(throwing: SongEngineError.failed(String(cString: err)))
                }
            }
        }
    }
}
