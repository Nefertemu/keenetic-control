import AppKit
import Vision
import XCTest

/// SwiftUI does not build its virtual AX tree in every XCTest host. Locate the
/// rendered label and send real AppKit input to this test's window instead.
@MainActor
enum NativeUIInteractions {
    nonisolated static func recognitionRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        // Avoid the Neural Engine's synchronous semaphore deadlock in the
        // Xcode 27 XCTest host. CPU OCR gives the same text assertions.
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        return request
    }

    /// Render at a fixed pixel density without changing the window's layout
    /// in points. Hosted macOS CI uses a 1× display, where 10pt route flags and
    /// disabled labels can lose letters in OCR despite being fully visible.
    static func renderedPNG(in view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    static func observations(in view: NSView) throws -> [VNRecognizedTextObservation] {
        let png = try renderedPNG(in: view)
        let request = try recognitionRequest()
        try VNImageRequestHandler(data: png, options: [:]).perform([request])
        return request.results ?? []
    }

    static func labels(in view: NSView) throws -> [String] {
        try observations(in: view).compactMap { $0.topCandidates(1).first?.string }
    }

    static func click(_ label: String, in view: NSView, window: NSWindow) throws {
        let observations = try observations(in: view)
        let candidates = observations.compactMap { observation in
            observation.topCandidates(1).first.map { (observation, $0) }
        }
        let selected = candidates.first { $0.1.string.localizedCaseInsensitiveCompare(label) == .orderedSame }
            ?? candidates.first { $0.1.string.contains(label) }
            ?? candidates.first { $0.1.string.localizedCaseInsensitiveContains(label) }
        let (match, text) = try XCTUnwrap(selected,
            "Cannot click missing label '\(label)': \(candidates.map { $0.1.string })")
        let range = try XCTUnwrap(text.string.range(of: label) ?? text.string.range(of: label, options: .caseInsensitive))
        let box = try text.boundingBox(for: range)?.boundingBox ?? match.boundingBox
        let local = NSPoint(x: view.bounds.minX + box.midX * view.bounds.width,
            y: view.isFlipped ? view.bounds.maxY - box.midY * view.bounds.height
                             : view.bounds.minY + box.midY * view.bounds.height)
        let location = view.convert(local, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Native controls may run a tracking loop during mouseDown; queue the
        // release first so that loop cannot wait for input from a person.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(release)
        }
    }
}
