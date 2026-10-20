import CoreML
import Foundation
import Vision

/// The person re-identification model (OSNet-AIN, from Torchreid, MIT license): a 256×128
/// picture of one person in, a 512-number description out, where the same person seen at
/// different moments comes out close and different people far apart, even in the same uniform.
/// It runs on the device (Neural Engine where available).
enum ReIDModel {
    /// The model, or nil if it couldn't be loaded (Cocut then falls back to Apple's image fingerprint).
    static let shared: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "PersonReID", withExtension: "mlmodelc") else {
            Log.error("Person re-identification model is missing from the app")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            Log.info("Person re-identification model loaded")
            return model
        } catch {
            Log.error("Person re-identification model couldn't be loaded: \(error.localizedDescription)")
            return nil
        }
    }()

    /// The description of the person in `region` (unit, bottom-left origin), unit length.
    static func embedding(_ handler: VNImageRequestHandler, region: CGRect, model: VNCoreMLModel) -> [Float]? {
        let request = VNCoreMLRequest(model: model)
        request.regionOfInterest = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // The model was trained on people stretched to 256×128, whatever their box.
        request.imageCropAndScaleOption = .scaleFill
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue else { return nil }
        let count = array.count
        guard count > 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        for i in 0..<count { values[i] = array[i].floatValue }
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return values.map { $0 / norm }
    }
}
