import Cocoa
import CoreML
import Vision

/// Detects clickable UI elements using the bundled YOLO11m CoreML model.
/// Returns bounding boxes in Quartz screen coordinates, **points** (top-left origin).
final class MLScanner {
    static let shared = MLScanner()
    private let modelTask: Task<VNCoreMLModel?, Never>

    private init() {
        modelTask = Task.detached(priority: .background) { await MLScanner.buildModel() }
    }

    // MARK: - Model loading

    private static func buildModel() async -> VNCoreMLModel? {
        guard let pkgURL = Bundle.main.url(forResource: "model", withExtension: "mlpackage") else {
            print("MLScanner: model.mlpackage not found — ML detection disabled.")
            return nil
        }
        do {
            let compiledURL = try compiledModelURL(for: pkgURL)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let mlModel = try MLModel(contentsOf: compiledURL, configuration: cfg)
            print("MLScanner: model ready ✓")
            return try VNCoreMLModel(for: mlModel)
        } catch {
            print("MLScanner: build failed: \(error)")
            return nil
        }
    }

    private static func compiledModelURL(for pkgURL: URL) throws -> URL {
        let fm   = FileManager.default
        let dir  = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VimHint/Models")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst  = dir.appendingPathComponent("model.mlmodelc")

        let srcMod = (try? pkgURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let dstMod = (try? dst.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate    ?? .distantPast

        if !fm.fileExists(atPath: dst.path) || srcMod > dstMod {
            print("MLScanner: compiling model (first run may take a moment)…")
            let tmp = try MLModel.compileModel(at: pkgURL)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: tmp, to: dst)
        }
        return dst
    }

    // MARK: - Inference

    func scan(screen: NSScreen, threshold: Float = 0.38) async -> [CGRect] {
        guard let vnModel = await modelTask.value else { return [] }
        return await Task.detached(priority: .userInitiated) { [self] in
            guard let img = captureScreen(screen) else { return [] }

            // Convert pixel dimensions → point dimensions
            // CGDisplayCreateImage returns physical pixels; AX uses logical points.
            // On Retina (2×): img.width = 2560 but screen.frame.width = 1280.
            let scale = screen.backingScaleFactor            // 2.0 on Retina, 1.0 otherwise
            let ptW   = CGFloat(img.width)  / scale          // screen width in points
            let ptH   = CGFloat(img.height) / scale          // screen height in points

            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill
            do {
                try VNImageRequestHandler(cgImage: img, options: [:]).perform([request])
            } catch {
                print("MLScanner: inference error: \(error)"); return []
            }

            guard let obs = (request.results as? [VNCoreMLFeatureValueObservation])?.first,
                  let arr = obs.featureValue.multiArrayValue else { return [] }

            return parseDetections(arr, ptW: ptW, ptH: ptH, screen: screen, threshold: threshold)
        }.value
    }

    // MARK: - Screen capture

    private func captureScreen(_ screen: NSScreen) -> CGImage? { // swiftlint:disable:this identifier_name
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()
        return CGDisplayCreateImage(id)
    }

    // MARK: - YOLO11m output — shape (1, 5, 8400)
    // ptr[ch * 8400 + i]: ch 0=x_center, 1=y_center, 2=w, 3=h, 4=conf (640×640 pixel space)

    private func parseDetections(_ arr: MLMultiArray, ptW: CGFloat, ptH: CGFloat, screen: NSScreen, threshold: Float = 0.38) -> [CGRect] {
        let N: Int = 8400
        let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: 5 * N)

        // Quartz top of this screen (for converting image Y → absolute Quartz Y)
        let primaryH    = NSScreen.screens[0].frame.height
        let quartzTop   = primaryH - screen.frame.maxY   // Quartz Y of this screen's top edge
        let quartzLeft  = screen.frame.minX              // Quartz X = NSScreen X

        let sx = ptW / 640   // model-units → points, X axis
        let sy = ptH / 640   // model-units → points, Y axis

        var candidates: [(CGRect, Float)] = []
        for i in 0..<N {
            let conf = ptr[4 * N + i]
            guard conf >= threshold else { continue }

            let xc = CGFloat(ptr[0 * N + i])
            let yc = CGFloat(ptr[1 * N + i])
            let w  = CGFloat(ptr[2 * N + i])
            let h  = CGFloat(ptr[3 * N + i])

            // Convert to Quartz absolute point coordinates
            let rect = CGRect(
                x: xc * sx - (w * sx) / 2 + quartzLeft,
                y: yc * sy - (h * sy) / 2 + quartzTop,   // Quartz Y from top of primary
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
