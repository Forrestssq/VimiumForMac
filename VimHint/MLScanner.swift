import Cocoa
import CoreML
import Vision

/// Detects clickable UI elements using the bundled YOLO11m CoreML model.
/// Returns bounding boxes in Quartz screen coordinates (top-left origin).
final class MLScanner {
    static let shared = MLScanner()

    // Model is compiled asynchronously on first init; scan() awaits it.
    private let modelTask: Task<VNCoreMLModel?, Never>

    private init() {
        modelTask = Task.detached(priority: .background) {
            return await MLScanner.buildModel()
        }
    }

    // MARK: - Model loading (compile .mlpackage → .mlmodelc and cache)

    private static func buildModel() async -> VNCoreMLModel? {
        guard let packageURL = Bundle.main.url(forResource: "model", withExtension: "mlpackage") else {
            print("MLScanner: model.mlpackage not found in bundle — ML detection disabled.")
            return nil
        }
        do {
            let compiledURL = try compiledModelURL(for: packageURL)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let mlModel = try MLModel(contentsOf: compiledURL, configuration: cfg)
            print("MLScanner: model ready ✓")
            return try VNCoreMLModel(for: mlModel)
        } catch {
            print("MLScanner: model build failed: \(error)")
            return nil
        }
    }

    /// Returns a path to the compiled .mlmodelc, compiling and caching if necessary.
    private static func compiledModelURL(for packageURL: URL) throws -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheDir = appSupport.appendingPathComponent("VimHint/Models")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let cachedURL = cacheDir.appendingPathComponent("model.mlmodelc")

        // Recompile only if the source package is newer than the cached compiled model
        let srcMod = (try? packageURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let dstMod = (try? cachedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        if !fm.fileExists(atPath: cachedURL.path) || srcMod > dstMod {
            print("MLScanner: compiling model (first run — may take a moment)…")
            let tmpURL = try MLModel.compileModel(at: packageURL)
            if fm.fileExists(atPath: cachedURL.path) {
                try fm.removeItem(at: cachedURL)
            }
            try fm.copyItem(at: tmpURL, to: cachedURL)
            print("MLScanner: model compiled and cached at \(cachedURL.path)")
        }

        return cachedURL
    }

    // MARK: - Inference

    func scan(screen: NSScreen) async -> [CGRect] {
        // Wait for model to finish compiling (no-op after first call)
        guard let vnModel = await modelTask.value else { return [] }

        return await Task.detached(priority: .userInitiated) { [self] in
            guard let screenshot = captureScreen(screen: screen) else { return [] }

            let screenW = CGFloat(screenshot.width)
            let screenH = CGFloat(screenshot.height)

            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill

            do {
                let handler = VNImageRequestHandler(cgImage: screenshot, options: [:])
                try handler.perform([request])
            } catch {
                print("MLScanner: inference error: \(error)")
                return []
            }

            guard let obs = (request.results as? [VNCoreMLFeatureValueObservation])?.first,
                  let multiArray = obs.featureValue.multiArrayValue else { return [] }

            return parseDetections(multiArray, screenW: screenW, screenH: screenH, screen: screen)
        }.value
    }

    // MARK: - Screen capture

    private func captureScreen(screen: NSScreen) -> CGImage? {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()
        return CGDisplayCreateImage(displayID)
    }

    // MARK: - YOLO11m output parsing — shape (1, 5, 8400)
    // Layout: ptr[channel × 8400 + i]
    // Channels: 0=x_center, 1=y_center, 2=width, 3=height, 4=confidence
    // Values are in the model's 640×640 input pixel space.

    private func parseDetections(
        _ arr: MLMultiArray,
        screenW: CGFloat,
        screenH: CGFloat,
        screen: NSScreen
    ) -> [CGRect] {
        let N = 8400
        let threshold: Float = 0.4

        let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: 5 * N)
        var candidates: [(CGRect, Float)] = []

        for i in 0..<N {
            let conf = ptr[4 * N + i]
            guard conf >= threshold else { continue }

            let xc = CGFloat(ptr[0 * N + i])
            let yc = CGFloat(ptr[1 * N + i])
            let w  = CGFloat(ptr[2 * N + i])
            let h  = CGFloat(ptr[3 * N + i])

            let sx = screenW / 640
            let sy = screenH / 640

            // Map to Quartz screen coordinates (top-left origin)
            let rect = CGRect(
                x: xc * sx - (w * sx) / 2 + screen.frame.minX,
                y: yc * sy - (h * sy) / 2,   // Quartz Y from top of primary screen
                width:  w * sx,
                height: h * sy
            )
            candidates.append((rect, conf))
        }

        return nms(candidates, iouThreshold: 0.4)
    }

    // MARK: - NMS

    private func nms(_ boxes: [(CGRect, Float)], iouThreshold: CGFloat) -> [CGRect] {
        let sorted = boxes.sorted { $0.1 > $1.1 }
        var suppressed = [Bool](repeating: false, count: sorted.count)
        var kept: [CGRect] = []

        for i in 0..<sorted.count {
            guard !suppressed[i] else { continue }
            kept.append(sorted[i].0)
            for j in (i + 1)..<sorted.count {
                if iou(sorted[i].0, sorted[j].0) > iouThreshold { suppressed[j] = true }
            }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let ia = inter.width * inter.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? ia / ua : 0
    }
}
