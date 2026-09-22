import AppKit
import Vision
import XCTest

/// SwiftUI does not build its virtual AX tree in every XCTest host. Locate the
/// rendered label and send real AppKit input to this test's window instead.
@MainActor
enum NativeUIInteractions {
    nonisolated static func recognitionRequest(technical: Bool = false) throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = technical ? ["en-US"] : ["ru-RU", "en-US"]
        if technical {
            request.usesLanguageCorrection = false
            request.customWords = ["auto", "reject", "disable", "Wireguard"]
        }
        // Avoid the Neural Engine's synchronous semaphore deadlock in the
        // Xcode 27 XCTest host. CPU OCR gives the same text assertions.
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        return request
    }

    /// Preserve the native backing scale. Rendering a layer-backed hosting
    /// view into an invented scale blurs its cached text on non-Retina CI.
    static func renderedPNG(in view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    static func observations(in view: NSView) throws -> [VNRecognizedTextObservation] {
        let png = try renderedPNG(in: view)
        return try observations(in: png)
    }

    static func observations(in png: Data, scale: Int = 1,
                             technical: Bool = false) throws -> [VNRecognizedTextObservation] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let source = try XCTUnwrap(bitmap.cgImage)
        let image: CGImage
        if scale > 1 {
            let context = try XCTUnwrap(CGContext(data: nil,
                width: source.width * scale, height: source.height * scale,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0,
                width: source.width * scale, height: source.height * scale))
            image = try XCTUnwrap(context.makeImage())
        } else { image = source }
        let request = try recognitionRequest(technical: technical)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    /// A supplemental English pass is opt-in for technical text, where
    /// language correction can turn flags into unrelated Russian words.
    /// Always retain the native pass: resampling can make small digits worse.
    static func labels(in png: Data, includeTechnicalPass: Bool = false) throws -> [String] {
        var results = try observations(in: png)
        if includeTechnicalPass {
            results += try observations(in: png, scale: 2, technical: true)
        }
        return results.compactMap { $0.topCandidates(1).first?.string }
    }

    static func labels(in view: NSView) throws -> [String] {
        try observations(in: view).compactMap { $0.topCandidates(1).first?.string }
    }

    static func click(_ label: String, in view: NSView, window: NSWindow) throws {
        try click(at: center(of: label, in: view), in: view, window: window)
    }

    static func center(of label: String, in view: NSView) throws -> NSPoint {
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
        return NSPoint(x: view.bounds.minX + box.midX * view.bounds.width,
            y: view.isFlipped ? view.bounds.maxY - box.midY * view.bounds.height
                             : view.bounds.minY + box.midY * view.bounds.height)
    }

    static func click(at point: NSPoint, in view: NSView, window: NSWindow) throws {
        let local = try XCTUnwrap(view.bounds.contains(point) ? point : nil,
                                 "Click must stay inside the actual test window")
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
