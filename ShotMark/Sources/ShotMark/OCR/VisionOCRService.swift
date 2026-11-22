import AppKit
import Vision

@MainActor
final class VisionOCRService: OCRServicing {
    func recognize(image: NSImage) async throws -> OCRResult {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw OCRError.invalidImage
        }

        return try await Task.detached(priority: .userInitiated) {
            try Self.recognize(cgImage: cgImage)
        }.value
    }

    nonisolated private static func recognize(cgImage: CGImage) throws -> OCRResult {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty
            else { return nil }
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                bounds: observation.boundingBox
            )
        }
        return try result(from: lines)
    }

    nonisolated static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        return request
    }

    nonisolated static func result(from lines: [OCRLine]) throws -> OCRResult {
        let topToBottom = lines.sorted { lhs, rhs in
            if lhs.bounds.midY != rhs.bounds.midY {
                return lhs.bounds.midY > rhs.bounds.midY
            }
            return lhs.bounds.origin.x < rhs.bounds.origin.x
        }
        var visualRows: [[OCRLine]] = []
        for line in topToBottom {
            if let index = visualRows.firstIndex(where: { belongsToSameVisualRow(line, as: $0) }) {
                visualRows[index].append(line)
            } else {
                visualRows.append([line])
            }
        }
        visualRows.sort { averageMidY(of: $0) > averageMidY(of: $1) }
        let orderedLines = visualRows.flatMap { row in
            row.sorted { $0.bounds.origin.x < $1.bounds.origin.x }
        }

        guard !orderedLines.isEmpty else { throw OCRError.noText }
        let confidence = orderedLines.reduce(Float.zero) { $0 + $1.confidence } / Float(orderedLines.count)
        return OCRResult(
            text: orderedLines.map(\.text).joined(separator: "\n"),
            averageConfidence: confidence
        )
    }

    nonisolated private static func belongsToSameVisualRow(
        _ line: OCRLine,
        as row: [OCRLine]
    ) -> Bool {
        guard !row.isEmpty else { return false }
        let lineBounds = line.bounds.standardized
        let averageHeight = row.reduce(CGFloat.zero) { $0 + $1.bounds.standardized.height } / CGFloat(row.count)
        let centerTolerance = max(0.01, min(lineBounds.height, averageHeight) * 0.5)
        if abs(lineBounds.midY - averageMidY(of: row)) <= centerTolerance {
            return true
        }

        return row.contains { member in
            let memberBounds = member.bounds.standardized
            let overlap = max(
                0,
                min(lineBounds.maxY, memberBounds.maxY) - max(lineBounds.minY, memberBounds.minY)
            )
            let shorterHeight = min(lineBounds.height, memberBounds.height)
            return shorterHeight > 0 && overlap / shorterHeight >= 0.5
        }
    }

    nonisolated private static func averageMidY(of row: [OCRLine]) -> CGFloat {
        row.reduce(CGFloat.zero) { $0 + $1.bounds.midY } / CGFloat(row.count)
    }
}

struct OCRLine: Sendable {
    let text: String
    let confidence: Float
    let bounds: CGRect
}
