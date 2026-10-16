import AceEngine
import Foundation

enum GenStage: Int {
    case songwriter, diffusion, decode, saving

    var label: String {
        switch self {
        case .songwriter: return "Writing the song"
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

struct EngineOptions: Equatable {
    var zeroCopy = true
    var lowMemory = false
    var useCPU = false
}

struct SongRequest {
    var caption: String
    var lyrics: String        // "" with songwriter = it writes them (Simple mode)
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
    var caption: String
    var lyrics: String
    var peakBytes: [UInt64]   // per stage
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
/// song takes minutes of blocking Metal (or CPU) work.
final class SongEngine: @unchecked Sendable {
    static let shared = SongEngine()

    private let handle: OpaquePointer?
    private let queue = DispatchQueue(label: "signature.engine", qos: .userInitiated)
    private var applied: EngineOptions?

    private init() {
        handle = ace_engine_create()
    }

    deinit {
        ace_engine_free(handle)
    }

    static var footprint: UInt64 { ace_memory_footprint() }

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
        options: EngineOptions,
        output: URL,
        onProgress: @escaping (GenStage, Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> SongResult? {
        guard let handle else { throw SongEngineError.unavailable }

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if self.applied != options {
                    var o = ace_engine_options(zero_copy: options.zeroCopy ? 1 : 0,
                                               low_memory: options.lowMemory ? 1 : 0,
                                               use_cpu: options.useCPU ? 1 : 0)
                    ace_engine_set_options(handle, &o)
                    self.applied = options
                }

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
                func c(_ s: String?, keepEmpty: Bool = false) -> UnsafePointer<CChar>? {
                    guard let s, keepEmpty || !s.isEmpty, let p = strdup(s) else { return nil }
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
                    lyrics: c(request.lyrics, keepEmpty: true),
                    vocal_language: c(request.language),
                    duration: Float(request.duration),
                    bpm: Int32(request.bpm),
                    seed: request.seed,
                    inference_steps: 0
                )
                // ace_song_info is large (lyrics buffer); keep it on the heap.
                let info = UnsafeMutablePointer<ace_song_info>.allocate(capacity: 1)
                defer { info.deallocate() }
                var err = [CChar](repeating: 0, count: 512)

                let rc = ace_engine_generate(
                    handle, &paths, &req, c(output.path), callback, user, info, &err, Int32(err.count)
                )

                switch rc {
                case 0:
                    let i = info.pointee
                    let peaks = withUnsafeBytes(of: i.peak_bytes) { Array($0.bindMemory(to: UInt64.self)) }
                    cont.resume(returning: SongResult(
                        seed: i.seed_used, bpm: Int(i.bpm),
                        key: Self.string(i.keyscale), duration: Double(i.duration),
                        caption: Self.string(i.caption), lyrics: Self.string(i.lyrics),
                        peakBytes: peaks))
                case 1:
                    cont.resume(returning: nil)
                default:
                    cont.resume(throwing: SongEngineError.failed(String(cString: err)))
                }
            }
        }
    }

    /// Fixed-size C char arrays import as tuples; read them as C strings.
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }
}
