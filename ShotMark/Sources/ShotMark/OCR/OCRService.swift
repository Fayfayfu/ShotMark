import AppKit

struct OCRResult: Sendable, Equatable {
    let text: String
    let averageConfidence: Float
}

enum OCRError: Error, LocalizedError, Equatable {
    case invalidImage
    case noText

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法读取当前截图。"
        case .noText:
            "未识别到文字。"
        }
    }
}

@MainActor
protocol OCRServicing {
    func recognize(image: NSImage) async throws -> OCRResult
}

@MainActor
protocol StringPasteboard: AnyObject {
    @discardableResult
    func write(_ string: String) -> Bool
}

@MainActor
final class SystemStringPasteboard: StringPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    func write(_ string: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}
