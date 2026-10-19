import Darwin
import Foundation

/// YuE2 on this device (experimental), through audio.cpp's C API.
///
/// audio.cpp ships as an optional, separately built `AudioCpp.framework`
/// (its own ggml, symbols hidden). It is loaded with dlopen so the app still
/// builds and runs when a build doesn't include it.
final class Yue2Engine {
    static let shared = Yue2Engine()

    struct Request {
        var style: String
        var lyrics: String
        var cot: String          // off | melody | full
        var seed: Int64
        var sound: SoundSettings
        /// Cap on music tokens (YuE2 writes ~25 per second of audio). Sizes the KV cache.
        var maxSemanticTokens: Int = 9000
        /// Classifier-free guidance runs two sequences and doubles the KV cache.
        var allowCFG: Bool = true
        /// Latent frames per VAE decode tile (~25 per second). The package default
        /// (1024 = ~40 s per tile) needs several GB of activations at once.
        var vaeTileFrames: Int = 256
    }

    /// YuE2-3B KV cache per token: 28 layers x (K+V) x 8 heads x 128 dims x f16.
    static let kvBytesPerToken: Int64 = 28 * 2 * 8 * 128 * 2

    enum Failure: LocalizedError {
        case notIncluded, incompatible, failed(String)
        var errorDescription: String? {
            switch self {
            case .notIncluded: return "This build doesn't include on-device YuE2. Use YuE2 on your PC, or ACE-Step here."
            case .incompatible: return "The bundled audio.cpp is a different version than this app expects."
            case .failed(let m): return m
            }
        }
    }

    // C signatures (include/audiocpp.h, ABI 0.x)
    private typealias AbiVersion = @convention(c) () -> UInt32
    private typealias LastError = @convention(c) () -> UnsafePointer<CChar>?
    private typealias OptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias OptionsSet = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias Free = @convention(c) (OpaquePointer?) -> Void
    private typealias RegistryCreate = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias ModelLoad = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, OpaquePointer?,
                                                  UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias SessionCreate = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                                      UnsafeRawPointer?, OpaquePointer?,
                                                      UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias RequestCreate = @convention(c) () -> OpaquePointer?
    private typealias RequestSetText = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias SessionRun = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias ResultAudio = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<Float>?>?,
                                                    UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?,
                                                    UnsafeMutablePointer<Int32>?) -> Int32

    private struct API {
        let abi: AbiVersion
        let lastError: LastError
        let optionsCreate: OptionsCreate
        let optionsSet: OptionsSet
        let optionsFree: Free
        let registryCreate: RegistryCreate
        let registryFree: Free
        let modelLoad: ModelLoad
        let modelFree: Free
        let sessionCreate: SessionCreate
        let sessionFree: Free
        let sessionRun: SessionRun
        let requestCreate: RequestCreate
        let requestFree: Free
        let requestSetText: RequestSetText
        let requestSetOption: OptionsSet
        let resultAudio: ResultAudio
        let resultFree: Free
    }

    private var api: API?
    private var loadAttempted = false
    private let queue = DispatchQueue(label: "com.anchdev.signature.yue2", qos: .userInitiated)

    /// Whether this build carries AudioCpp.framework.
    var isIncluded: Bool { frameworkPath != nil }

    private var frameworkPath: String? {
        guard let dir = Bundle.main.privateFrameworksPath else { return nil }
        let p = dir + "/AudioCpp.framework/AudioCpp"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    private func load() throws -> API {
        if let api { return api }
        // Same as the ACE-Step engine: Metal residency sets keep freed buffers
        // wired for minutes, which counts against the app's memory limit.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        guard let path = frameworkPath, let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            if let e = dlerror() { LogCapture.shared.log("YuE2: dlopen failed: \(String(cString: e))") }
            throw Failure.notIncluded
        }
        func sym<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw Failure.incompatible }
            return unsafeBitCast(p, to: T.self)
        }
        let a = API(
            abi: try sym("audiocpp_abi_version", AbiVersion.self),
            lastError: try sym("audiocpp_last_error", LastError.self),
            optionsCreate: try sym("audiocpp_options_create", OptionsCreate.self),
            optionsSet: try sym("audiocpp_options_set", OptionsSet.self),
            optionsFree: try sym("audiocpp_options_free", Free.self),
            registryCreate: try sym("audiocpp_registry_create", RegistryCreate.self),
            registryFree: try sym("audiocpp_registry_free", Free.self),
            modelLoad: try sym("audiocpp_model_load", ModelLoad.self),
            modelFree: try sym("audiocpp_model_free", Free.self),
            sessionCreate: try sym("audiocpp_session_create", SessionCreate.self),
            sessionFree: try sym("audiocpp_session_free", Free.self),
            sessionRun: try sym("audiocpp_session_run", SessionRun.self),
            requestCreate: try sym("audiocpp_request_create", RequestCreate.self),
            requestFree: try sym("audiocpp_request_free", Free.self),
            requestSetText: try sym("audiocpp_request_set_text", RequestSetText.self),
            requestSetOption: try sym("audiocpp_request_set_option", OptionsSet.self),
            resultAudio: try sym("audiocpp_result_audio", ResultAudio.self),
            resultFree: try sym("audiocpp_result_free", Free.self))
        guard a.abi() >> 16 == 0 else { throw Failure.incompatible }
        // Optional Signature hook (build-audiocpp.sh): stage timings + load progress to stdout.
        typealias SetLogging = @convention(c) (Int32) -> Void
        if let p = dlsym(h, "audiocpp_signature_set_logging") {
            unsafeBitCast(p, to: SetLogging.self)(1)
        }
        api = a
        LogCapture.shared.log(String(format: "YuE2: audio.cpp ABI %d.%d loaded", (a.abi() >> 16) & 0xff, (a.abi() >> 8) & 0xff))
        return a
    }

    private func err(_ a: API, _ what: String) -> Failure {
        let detail = a.lastError().map { String(cString: $0) } ?? ""
        LogCapture.shared.log("YuE2: \(what) failed: \(detail)")
        return .failed("YuE2 \(what) failed\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Generate one song into `output` (WAV). Blocking work runs off the main thread.
    func generate(_ r: Request, modelDir: URL, mainGGUF: String, vaeGGUF: String, output: URL) async throws -> Double {
        let a = try load()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let root = try Self.runRoot(for: modelDir, vaeTileFrames: r.vaeTileFrames)
                    cont.resume(returning: try self.run(a, r, modelDir: root, mainGGUF: mainGGUF, vaeGGUF: vaeGGUF, output: output))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// A sibling model root for this run: hard links to the downloaded GGUFs plus
    /// copies of the sidecars with the VAE tile size set for this device. The
    /// downloaded package stays untouched (its sizes are how downloads are verified).
    static func runRoot(for modelDir: URL, vaeTileFrames: Int) throws -> URL {
        let fm = FileManager.default
        let root = modelDir.deletingLastPathComponent().appendingPathComponent("Yue2-3B-run", isDirectory: true)
        let side = root.appendingPathComponent("sidecars", isDirectory: true)
        try fm.createDirectory(at: side, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: modelDir.path)) ?? [] where name.hasSuffix(".gguf") {
            let src = modelDir.appendingPathComponent(name), dst = root.appendingPathComponent(name)
            let same = (try? fm.attributesOfItem(atPath: dst.path)[.systemFileNumber] as? NSNumber)
                == (try? fm.attributesOfItem(atPath: src.path)[.systemFileNumber] as? NSNumber)
            if fm.fileExists(atPath: dst.path) && same { continue }
            try? fm.removeItem(at: dst)
            do { try fm.linkItem(at: src, to: dst) } catch { try fm.createSymbolicLink(at: dst, withDestinationURL: src) }
        }
        let srcSide = modelDir.appendingPathComponent("sidecars", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: srcSide.path)) ?? [] {
            let src = srcSide.appendingPathComponent(name), dst = side.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            if name == "yue2-vae-config.json", let data = try? Data(contentsOf: src),
               var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                json["decode_core_frames"] = vaeTileFrames
                let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: dst)
            } else {
                try fm.copyItem(at: src, to: dst)
            }
        }
        return root
    }

    private func run(_ a: API, _ r: Request, modelDir: URL, mainGGUF: String, vaeGGUF: String, output: URL) throws -> Double {
        var registry: OpaquePointer?
        guard a.registryCreate(nil, &registry) == 0 else { throw err(a, "setup") }
        defer { a.registryFree(registry) }

        // audiocpp_model_config { family_hint, config_id, weight_id, model_spec_override }
        let family = strdup("yue2")
        defer { free(family) }
        var config: [UnsafePointer<CChar>?] = [UnsafePointer(family), nil, nil, nil]
        var model: OpaquePointer?
        let rc = config.withUnsafeMutableBytes { buf in
            a.modelLoad(registry, modelDir.path, UnsafeRawPointer(buf.baseAddress), nil, &model)
        }
        guard rc == 0 else { throw err(a, "model load") }
        defer { a.modelFree(model) }

        let opts = a.optionsCreate()
        defer { a.optionsFree(opts) }
        _ = a.optionsSet(opts, "yue2.model_gguf", mainGGUF)
        _ = a.optionsSet(opts, "yue2.vae_gguf", vaeGGUF)

        // audiocpp_backend_config { backend, device, threads }
        let backendName = strdup("metal")
        defer { free(backendName) }
        struct Backend { var backend: UnsafePointer<CChar>?; var device: Int32; var threads: Int32 }
        var backend = Backend(backend: UnsafePointer(backendName), device: 0,
                              threads: Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var session: OpaquePointer?
        let src = withUnsafePointer(to: &backend) { p in
            a.sessionCreate(model, "gen", "offline", UnsafeRawPointer(p), opts, &session)
        }
        guard src == 0 else { throw err(a, "session") }
        defer { a.sessionFree(session) }

        let req = a.requestCreate()
        defer { a.requestFree(req) }
        let lyrics = r.lyrics.isEmpty ? "[instrumental]" : r.lyrics
        _ = a.requestSetText(req, lyrics, nil)
        _ = a.requestSetOption(req, "lyrics", lyrics)
        _ = a.requestSetOption(req, "style", r.style)
        _ = a.requestSetOption(req, "cot", r.cot)
        let seed = r.seed >= 0 ? r.seed : Int64.random(in: 0..<Int64(Int32.max))
        _ = a.requestSetOption(req, "seed", String(seed))
        for (k, v) in Self.options(for: r.sound, allowCFG: r.allowCFG) { _ = a.requestSetOption(req, k, v) }
        _ = a.requestSetOption(req, "semantic_max_tokens", String(r.maxSemanticTokens))
        LogCapture.shared.log("YuE2: max \(r.maxSemanticTokens) music tokens (~\(r.maxSemanticTokens / 25) s), guidance \(r.allowCFG ? "on" : "off (memory)"), VAE tiles \(r.vaeTileFrames) frames")

        LogCapture.shared.log("YuE2: generating (cot \(r.cot), seed \(seed))")
        var result: OpaquePointer?
        guard a.sessionRun(session, req, &result) == 0 else { throw err(a, "generation") }
        defer { a.resultFree(result) }

        var samples: UnsafePointer<Float>?
        var frames = 0
        var rate: Int32 = 0
        var channels: Int32 = 0
        guard a.resultAudio(result, &samples, &frames, &rate, &channels) == 0, let samples, frames > 0, rate > 0 else {
            throw err(a, "audio output")
        }
        try WAV.write(samples, frames: frames, channels: Int(max(1, channels)), rate: Int(rate), to: output)
        return Double(frames) / Double(rate)
    }

    /// Same slider mapping as the PC Hub (pc/hub/signature_hub/yue2.py).
    static func options(for s: SoundSettings, allowCFG: Bool = true) -> [(String, String)] {
        var o: [(String, String)] = []
        if abs(s.weirdness - 0.5) > 0.001 {
            o.append(("semantic_temperature", String(format: "%.3f", 0.7 + 0.6 * s.weirdness)))
            o.append(("semantic_top_p", String(format: "%.3f", min(0.99, 0.9 + 0.1 * s.weirdness))))
        }
        if !allowCFG {
            // 1.0 exactly = single sequence (cot=off would otherwise default to 1.01 and run CFG).
            o.append(("guidance_scale", "1.0"))
        } else if abs(s.styleInfluence - 0.5) > 0.001 {
            o.append(("guidance_scale", String(format: "%.3f", max(1.0, 1.01 + (s.styleInfluence - 0.5) * 3.0))))
        }
        o.append(("num_inference_steps", s.quality == .fast ? "6" : s.quality == .high ? "16" : "8"))
        return o
    }
}

/// 16-bit PCM WAV writer for float samples (interleaved).
enum WAV {
    static func write(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, rate: Int, to url: URL) throws {
        let count = frames * channels
        var data = Data(capacity: 44 + count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(count * 2))
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}
