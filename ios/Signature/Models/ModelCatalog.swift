import Foundation
import os

// MARK: - Catalog of every ACE-Step 1.5 GGUF (Serveurperso/ACE-Step-1.5-GGUF)

enum Quant: String, CaseIterable, Identifiable, Codable {
    case q4 = "Q4_K_M", q5 = "Q5_K_M", q6 = "Q6_K", q8 = "Q8_0", bf16 = "BF16"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .q4: return "Compact"
        case .q5: return "Balanced"
        case .q6: return "High"
        case .q8: return "Very high"
        case .bf16: return "Full"
        }
    }
}

struct ModelFile: Identifiable, Hashable {
    let id: String          // file name
    let bytes: Int64
    var url: URL { URL(string: "https://huggingface.co/Serveurperso/ACE-Step-1.5-GGUF/resolve/main/\(id)")! }
}

/// A DiT ("music model") in all the quantizations that exist for it.
struct MusicModel: Identifiable, Hashable {
    let id: String              // file stem, e.g. "acestep-v15-turbo"
    let name: String
    let blurb: String
    let steps: Int
    let xl: Bool
    let sizes: [Quant: Int64]

    var quants: [Quant] { Quant.allCases.filter { sizes[$0] != nil } }
    func file(_ q: Quant) -> ModelFile? { sizes[q].map { ModelFile(id: "\(id)-\(q.rawValue).gguf", bytes: $0) } }
    var smallest: Quant { quants.first ?? .q8 }
}

struct SongwriterModel: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let sizes: [Quant: Int64]
    var quants: [Quant] { Quant.allCases.filter { sizes[$0] != nil } }
    func file(_ q: Quant) -> ModelFile? { sizes[q].map { ModelFile(id: "\(id)-\(q.rawValue).gguf", bytes: $0) } }
}

enum Catalog {
    private static let std: [Quant: Int64] = [.q4: 1_445_710_208, .q5: 1_700_140_160, .q6: 1_970_472_000, .q8: 2_549_527_936, .bf16: 4_791_642_016]
    private static let turboSz: [Quant: Int64] = [.q4: 1_445_710_272, .q5: 1_700_140_224, .q6: 1_970_472_064, .q8: 2_549_528_000, .bf16: 4_791_642_080]
    private static let shiftSz: [Quant: Int64] = [.q4: 1_445_710_240, .q5: 1_700_140_192, .q6: 1_970_472_032, .q8: 2_549_527_968, .bf16: 4_791_642_048]
    private static let contSz: [Quant: Int64] = [.q4: 1_445_710_240, .q5: 1_700_140_192, .q6: 1_970_472_032, .q8: 2_549_527_968, .bf16: 4_791_642_080]
    private static let xlStd: [Quant: Int64] = [.q4: 2_989_922_656, .q5: 3_527_566_432, .q6: 4_098_812_960, .q8: 5_305_828_704, .bf16: 9_978_530_784]
    private static let xlTurbo: [Quant: Int64] = [.q4: 2_989_922_688, .q5: 3_527_566_464, .q6: 4_098_812_992, .q8: 5_305_828_736, .bf16: 9_978_530_816]
    private static let xlST: [Quant: Int64] = [.q4: 2_989_922_720, .q5: 3_527_566_496, .q6: 4_098_813_024, .q8: 5_305_828_768, .bf16: 9_978_530_816]

    static let music: [MusicModel] = [
        .init(id: "acestep-v15-turbo", name: "v1.5 Turbo", blurb: "Fast, great all-rounder. Start here.", steps: 8, xl: false, sizes: turboSz),
        .init(id: "acestep-v15-turbo-shift3", name: "v1.5 Turbo Shift3", blurb: "Turbo tuned for stronger structure.", steps: 8, xl: false, sizes: shiftSz),
        .init(id: "acestep-v15-turbo-shift1", name: "v1.5 Turbo Shift1", blurb: "Turbo tuned for finer detail.", steps: 8, xl: false, sizes: shiftSz),
        .init(id: "acestep-v15-turbo-continuous", name: "v1.5 Turbo Continuous", blurb: "Turbo with a smoother noise schedule.", steps: 8, xl: false, sizes: contSz),
        .init(id: "acestep-v15-sft", name: "v1.5 SFT", blurb: "Higher quality, 50 steps (about 6x slower).", steps: 50, xl: false, sizes: std),
        .init(id: "acestep-v15-base", name: "v1.5 Base", blurb: "Raw base model, 50 steps. For experiments.", steps: 50, xl: false, sizes: std),
        .init(id: "acestep-v15-sftturbo50", name: "v1.5 SFT-Turbo", blurb: "Merge of SFT and Turbo.", steps: 0, xl: false,
              sizes: [.q8: 2_549_527_936, .bf16: 4_791_642_016]),
        .init(id: "acestep-v15-xl-turbo", name: "XL Turbo", blurb: "Bigger and richer. Needs a Pro iPhone.", steps: 8, xl: true, sizes: xlTurbo),
        .init(id: "acestep-v15-xl-sft", name: "XL SFT", blurb: "Best quality, 50 steps. Pro iPhones only.", steps: 50, xl: true, sizes: xlStd),
        .init(id: "acestep-v15-xl-base", name: "XL Base", blurb: "XL base model, 50 steps.", steps: 50, xl: true, sizes: xlStd),
        .init(id: "acestep-v15-xl-sftturbo50", name: "XL SFT-Turbo", blurb: "XL merge of SFT and Turbo.", steps: 0, xl: true, sizes: xlST),
    ]

    static let songwriters: [SongwriterModel] = [
        .init(id: "acestep-5Hz-lm-0.6B", name: "Songwriter 0.6B", blurb: "Small and quick. Fits every phone.",
              sizes: [.q8: 709_846_656, .bf16: 1_331_108_128]),
        .init(id: "acestep-5Hz-lm-1.7B", name: "Songwriter 1.7B", blurb: "Better lyrics and structure.",
              sizes: [.q8: 1_975_837_568, .bf16: 3_713_827_104]),
        .init(id: "acestep-5Hz-lm-4B", name: "Songwriter 4B", blurb: "Best writing. 12 GB iPhones.",
              sizes: [.q5: 3_025_965_984, .q6: 3_442_713_504, .q8: 4_457_323_648, .bf16: 8_384_454_592]),
    ]

    static let textEncoders: [Quant: ModelFile] = [
        .q8: .init(id: "Qwen3-Embedding-0.6B-Q8_0.gguf", bytes: 784_144_960),
        .bf16: .init(id: "Qwen3-Embedding-0.6B-BF16.gguf", bytes: 1_196_890_592),
    ]
    static let vae = ModelFile(id: "vae-BF16.gguf", bytes: 337_420_928)

    static func music(_ id: String) -> MusicModel? { music.first { $0.id == id } }
    static func songwriter(_ id: String) -> SongwriterModel? { songwriters.first { $0.id == id } }

    static var allFiles: [ModelFile] {
        music.flatMap { m in m.quants.compactMap(m.file) }
            + songwriters.flatMap { s in s.quants.compactMap(s.file) }
            + Array(textEncoders.values) + [vae]
    }
}

// MARK: - Device fit

enum Fit: Comparable {
    case good, tight, tooBig
    var label: String {
        switch self {
        case .good: return "Fits"
        case .tight: return "Tight"
        case .tooBig: return "Too big"
        }
    }
}

enum Device {
    /// Memory iOS lets this app use right now plus what it already uses.
    static var budget: Int64 {
        Int64(os_proc_available_memory()) + Int64(SongEngine.footprint)
    }

    static var budgetGB: Double { Double(budget) / 1_073_741_824 }

    /// 4 GB iPhones get roughly 2-2.5 GB; anything under 3 GB runs Lite.
    static var isLowMemory: Bool { budgetGB < 3.0 }

    /// Only one model is loaded at a time, so the largest file decides.
    /// Mapped weights are partly reclaimable, so this is deliberately rough.
    static func fit(bytes: Int64) -> Fit {
        let ratio = Double(bytes) / Double(max(budget, 1))
        if ratio <= 0.55 { return .good }
        if ratio <= 0.85 { return .tight }
        return .tooBig
    }
}
