import Foundation

/// Evaluates whether a GGUF model fits comfortably in available memory.
///
/// Footprint formula:
///   model_size (file on disk ≈ VRAM needed) + KV cache (context × layers × heads × dim × 2 × quant_factor)
///   For Q4_K_M: ~0.56 bytes/param, KV cache ≈ model_size × (context / 2048) × 0.15
///
/// Classification:
///   ✅ Recommended — fits with >2 GB headroom
///   ⚠️ Tight — fits but <2 GB headroom
///   ⛔ Won't fit — exceeds Metal budget or free RAM
enum ModelFitEvaluator {
    enum FitClass: String, Sendable {
        case recommended = "recommended"
        case tight = "tight"
        case wontFit = "wont_fit"

        var label: String {
            switch self {
            case .recommended: return "Recommended"
            case .tight: return "Tight Fit"
            case .wontFit: return "Won't Fit"
            }
        }

        var systemImage: String {
            switch self {
            case .recommended: return "checkmark.circle.fill"
            case .tight: return "exclamationmark.triangle.fill"
            case .wontFit: return "xmark.octagon.fill"
            }
        }
    }

    struct Evaluation: Sendable {
        let fitClass: FitClass
        let estimatedFootprintGB: Double
        let availableGB: Double
        let headroomGB: Double
    }

    /// Headroom threshold: below this (in GB) after loading model, classify as tight.
    private static let tightHeadroomGB = 2.0

    static func evaluate(
        modelSizeGB: Double,
        hardware: ExtendedHardwareProbe.Snapshot,
        contextLength: Int = 2048
    ) -> Evaluation {
        // KV cache overhead ≈ 15% of model size per 2048 context tokens
        let kvOverheadFactor = Double(contextLength) / 2048.0 * 0.15
        let totalFootprint = modelSizeGB * (1.0 + kvOverheadFactor)

        // Use Metal budget as the ceiling (it accounts for shared memory architecture)
        let available = min(hardware.freeMemoryGB, hardware.metalBudgetGB)
        let headroom = available - totalFootprint

        let fitClass: FitClass
        if headroom < 0 {
            fitClass = .wontFit
        } else if headroom < tightHeadroomGB {
            fitClass = .tight
        } else {
            fitClass = .recommended
        }

        return Evaluation(
            fitClass: fitClass,
            estimatedFootprintGB: totalFootprint,
            availableGB: available,
            headroomGB: headroom
        )
    }

    /// Evaluates all catalog models and returns the largest one classified as .recommended.
    static func recommendedModel(
        from models: [DownloadableRuntimeModel],
        hardware: ExtendedHardwareProbe.Snapshot,
        contextLength: Int = 2048
    ) -> DownloadableRuntimeModel? {
        models
            .sorted { $0.approximateSizeInGigabytes > $1.approximateSizeInGigabytes }
            .first { model in
                let eval = evaluate(
                    modelSizeGB: model.approximateSizeInGigabytes,
                    hardware: hardware,
                    contextLength: contextLength
                )
                return eval.fitClass == .recommended
            }
    }
}
