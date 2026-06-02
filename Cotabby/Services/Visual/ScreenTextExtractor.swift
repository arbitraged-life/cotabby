import CoreGraphics
import Foundation
import Logging
@preconcurrency import Vision

/// File overview:
/// Runs OCR over a captured window screenshot and returns a reading-order text excerpt.
/// This is the bridge between raw image capture and the existing text-only local LLM runtime.
///
/// We deliberately downsample very large screenshots before OCR. The goal is not archival fidelity;
/// it is fast, good-enough semantic extraction for autocomplete context.
///
/// DEPRECATED:
/// The current autocomplete request path no longer injects OCR-derived context.
/// Keep this extractor only for legacy experiments until the context rewrite lands.

struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
}

enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case imageTooSmall
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return "No usable visible text was recognized in the screenshot."
        case .imageTooSmall:
            return "Screenshot was too small for reliable text recognition."
        case let .ocrFailed(message):
            return "Screenshot OCR failed: \(message)"
        }
    }
}

struct ScreenTextExtractor {
    let maxImageDimension: Int
    let maxRecognizedCharacters: Int

    init(
        maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
        maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters
    ) {
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    /// Performs OCR asynchronously so the main actor is not blocked by Vision processing.
    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let startedAt = Date()

        // Vision's text recognizer can trap (EXC_BREAKPOINT) on degenerate, near-zero-area images —
        // e.g. when a tiny floating/status window becomes frontmost and gets captured. Reject those
        // up front instead of feeding them to VNImageRequestHandler. (#502)
        let minimumOCRDimension = 8
        guard image.width >= minimumOCRDimension, image.height >= minimumOCRDimension else {
            log("ocr-skipped reason=too-small size=\(image.width)x\(image.height)")
            throw ScreenTextExtractionError.imageTooSmall
        }

        let preparedImage = downsampledImageIfNeeded(image)
        let wasDownsampled = preparedImage.width != image.width || preparedImage.height != image.height

        log(
            "ocr-start input=\(image.width)x\(image.height) prepared=\(preparedImage.width)x\(preparedImage.height) " +
                "downsampled=\(wasDownsampled)"
        )

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Guards against double-resume: Vision can invoke the request completion handler AND
                // surface an error from handler.perform(), which would resume the continuation twice
                // and trap with SIGTRAP. Only the first resume is honored. (#502)
                let didResume = ManagedAtomicFlag()
                func finish(_ body: () -> Void) {
                    guard didResume.testAndSet() else { return }
                    body()
                }

                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                        finish { continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription)) }
                        return
                    }

                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    let orderedLines = observations
                        .sorted {
                            if Swift.abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                                return $0.boundingBox.minY > $1.boundingBox.minY
                            }

                            return $0.boundingBox.minX < $1.boundingBox.minX
                        }
                        .compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    let joinedText = orderedLines.joined(separator: "\n")
                    let cappedText = String(joinedText.prefix(maxRecognizedCharacters))

                    guard !cappedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.log("ocr-empty elapsed_ms=\(elapsedMilliseconds) lines=\(orderedLines.count)")
                        finish { continuation.resume(throwing: ScreenTextExtractionError.noRecognizedText) }
                        return
                    }

                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    self.log(
                        "ocr-success elapsed_ms=\(elapsedMilliseconds) lines=\(orderedLines.count) chars=\(cappedText.count) " +
                            "preview=\(self.preview(cappedText))"
                    )

                    finish { continuation.resume(returning: ExtractedScreenText(text: cappedText, lineCount: orderedLines.count)) }
                }

                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.012

                do {
                    let handler = VNImageRequestHandler(cgImage: preparedImage, options: [:])
                    try handler.perform([request])
                } catch {
                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                    finish { continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription)) }
                }
            }
        }
    }

    /// Keeps OCR latency bounded on very large Retina windows by scaling the image to a reasonable
    /// max dimension before text recognition.
    private func downsampledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)

        guard largestDimension > maxImageDimension else {
            return image
        }

        let scale = CGFloat(maxImageDimension) / CGFloat(largestDimension)
        let targetWidth = max(Int(CGFloat(width) * scale), 1)
        let targetHeight = max(Int(CGFloat(height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private func log(_ message: String) {
        // OCR log messages include preview text from the user's screen. Route them through
        // the debug gate so they only appear when the developer explicitly opts in.
        CotabbyDebugOptions.log(message)
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}

/// Minimal thread-safe one-shot flag. Used to ensure a checked continuation is resumed exactly once
/// even if Vision delivers both a completion-handler callback and a thrown error from perform(). (#502)
private final class ManagedAtomicFlag {
    private var value = false
    private let lock = NSLock()

    /// Atomically sets the flag and returns true only on the first call.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
