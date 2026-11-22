import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

@MainActor
protocol ScreenImageProviding {
    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage]
}

enum CaptureError: Error {
    case permissionDenied
    case noDisplays
    case displayTopologyChanged
    case captureTimedOut
    case captureFailed(any Error)
}

@MainActor
final class ScreenImageProvider: ScreenImageProviding {
    struct CaptureDimensions: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        let logicalSize: NSSize
    }

    private let permissionChecker: () -> Bool
    private let authorizationRequester: () -> Bool
    private let contentLoader: () async throws -> SCShareableContent
    private let captureTimeout: Duration

    init(
        permissionChecker: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
        authorizationRequester: @escaping () -> Bool = CGRequestScreenCaptureAccess,
        contentLoader: @escaping () async throws -> SCShareableContent = {
            try await SCShareableContent.current
        },
        captureTimeout: Duration = .seconds(10)
    ) {
        self.permissionChecker = permissionChecker
        self.authorizationRequester = authorizationRequester
        self.contentLoader = contentLoader
        self.captureTimeout = captureTimeout
    }

    func captureDisplays() async throws -> [CGDirectDisplayID: NSImage] {
        guard permissionChecker() || authorizationRequester() else {
            throw CaptureError.permissionDenied
        }

        do {
            let result = try await withStartupTimeout {
                CaptureResultBox(images: try await self.captureDisplaysWithoutTimeout())
            }
            return result.images
        } catch let captureError as CaptureError {
            throw captureError
        } catch {
            throw Self.captureError(for: error)
        }
    }

    private func captureDisplaysWithoutTimeout() async throws -> [CGDirectDisplayID: NSImage] {
        let content = try await contentLoader()
        guard !content.displays.isEmpty else {
            throw CaptureError.noDisplays
        }

        var images: [CGDirectDisplayID: NSImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            guard let dimensions = Self.captureDimensions(
                contentRect: filter.contentRect,
                pointPixelScale: CGFloat(filter.pointPixelScale)
            ) else {
                throw CaptureError.captureFailed(CaptureDimensionError.invalidGeometry)
            }
            let configuration = SCStreamConfiguration()
            configuration.width = dimensions.pixelWidth
            configuration.height = dimensions.pixelHeight
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            images[display.displayID] = NSImage(
                cgImage: cgImage,
                size: dimensions.logicalSize
            )
        }
        return images
    }

    private func withStartupTimeout(
        _ operation: @escaping @MainActor () async throws -> CaptureResultBox
    ) async throws -> CaptureResultBox {
        try await withCheckedThrowingContinuation { continuation in
            let race = StartupTimeoutRace(continuation: continuation)
            let operationTask = Task { @MainActor in
                do {
                    let result = try await operation()
                    race.resume(returning: result)
                } catch {
                    race.resume(throwing: error)
                }
            }

            Task { @MainActor in
                try? await Task.sleep(for: captureTimeout)
                guard !Task.isCancelled, !race.isResolved else { return }
                operationTask.cancel()
                race.resume(throwing: CaptureError.captureTimedOut)
            }
        }
    }

    nonisolated static func captureError(for error: any Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case SCStreamError.userDeclined.rawValue:
                return .permissionDenied
            case SCStreamError.noDisplayList.rawValue,
                 SCStreamError.noCaptureSource.rawValue:
                return .noDisplays
            default:
                break
            }
        }
        return .captureFailed(error)
    }

    nonisolated static func captureDimensions(
        contentRect: CGRect,
        pointPixelScale: CGFloat
    ) -> CaptureDimensions? {
        guard contentRect.width.isFinite,
              contentRect.height.isFinite,
              pointPixelScale.isFinite,
              contentRect.width > 0,
              contentRect.height > 0,
              pointPixelScale > 0
        else { return nil }

        let pixelWidth = (contentRect.width * pointPixelScale).rounded(.up)
        let pixelHeight = (contentRect.height * pointPixelScale).rounded(.up)
        guard pixelWidth <= CGFloat(Int.max), pixelHeight <= CGFloat(Int.max) else { return nil }
        return CaptureDimensions(
            pixelWidth: Int(pixelWidth),
            pixelHeight: Int(pixelHeight),
            logicalSize: contentRect.size
        )
    }
}

@MainActor
private final class CaptureResultBox: @unchecked Sendable {
    let images: [CGDirectDisplayID: NSImage]

    init(images: [CGDirectDisplayID: NSImage]) {
        self.images = images
    }
}

@MainActor
private final class StartupTimeoutRace {
    private var continuation: CheckedContinuation<CaptureResultBox, any Error>?

    init(continuation: CheckedContinuation<CaptureResultBox, any Error>) {
        self.continuation = continuation
    }

    var isResolved: Bool { continuation == nil }

    func resume(returning value: CaptureResultBox) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

private enum CaptureDimensionError: Error {
    case invalidGeometry
}
