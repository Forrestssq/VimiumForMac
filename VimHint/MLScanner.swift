import Cocoa
import CoreML
import Vision

/// Detects clickable UI elements using the bundled YOLO11m CoreML model.
/// Returns bounding boxes in Quartz screen coordinates (top-left origin).
final class MLScanner {
    static let shared = MLScanner()

    private var vnModel: VNCoreMLModel?

    private init() {
        loadModel()
    }

    private func loadModel() {
        guard let url = Bundle.main.url(forResource: "model", withExtension: "mlpackage") else {
            print("MLScanner: model.mlpackage not found in bundle — ML detection disabled.")
            return
        }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let mlModel = try MLModel(contentsOf: url, configuration: cfg)
            vnModel = try VNCoreMLModel(for: mlModel)
        } catch {
            print("MLScanner: model load failed: \(error)")
        }
    }

    func scan(screen: NSScreen) async -> [CGRect] {
        guard let vnModel else { return [] }

        return await Task.detached(priority: .userInitiated) { [self] in
            guard let screenshot = captureScreen(screen: screen) else { return [] }

            let screenW = CGFloat(screenshot.width)
            let screenH = CGFloat(screenshot.height)

            var raw: MLMultiArray?
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill  // stretch to 640×640, matches training

            do {
                let handler = VNImageRequestHandler(cgImage: screenshot, options: [:])
                try handler.perform([request])
            } catch {
                print("MLScanner: inference error: \(error)")
                return []
            }

            // The model returns a raw feature array (shape 1×5×8400)
            if let obs = (request.results as? [VNCoreMLFeatureValueObservation])?.first {
                raw = obs.featureValue.multiArrayValue
            } else if let obs = request.results?.first as? VNCoreMLFeatureValueObservation {
                raw = obs.featureValue.multiArrayValue
            }

            guard let multiArray = raw else { return [] }
            return parseDetections(multiArray, screenW: screenW, screenH: screenH, screen: screen)
        }.value
    }

    // MARK: - Screen capture

    private func captureScreen(screen: NSScreen) -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return CGDisplayCreateImage(CGMainDisplayID()) }
        return CGDisplayCreateImage(displayID)
    }

    // MARK: - YOLO11m output parsing — shape (1, 5, 8400)
    // Layout: [batch=0, channel, detection_index]
    // Channels: 0=x_center, 1=y_center, 2=width, 3=height, 4=confidence
    // Values are in the model's 640×640 input pixel space.

    private func parseDetections(_ arr: MLMultiArray, screenW: CGFloat, screenH: CGFloat, screen: NSScreen) -> [CGRect] {
        let N = 8400
        let confidenceThreshold: Float = 0.4

        let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: 5 * N)

        var candidates: [(CGRect, Float)] = []
        candidates.reserveCapacity(256)

        for i in 0..<N {
            let conf = ptr[4 * N + i]
            guard conf >= confidenceThreshold else { continue }

            let xc = CGFloat(ptr[0 * N + i])
            let yc = CGFloat(ptr[1 * N + i])
            let w  = CGFloat(ptr[2 * N + i])
            let h  = CGFloat(ptr[3 * N + i])

            // Scale from 640×640 → actual capture resolution
            let sx = screenW / 640
            let sy = screenH / 640

            let screenX = xc * sx + screen.frame.minX
            let screenY = yc * sy  // Quartz Y (top-down from primary screen top)
            let screenW2 = w * sx
            let screenH2 = h * sy

            let rect = CGRect(
                x: screenX - screenW2 / 2,
                y: screenY - screenH2 / 2,
                width: screenW2,
                height: screenH2
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
