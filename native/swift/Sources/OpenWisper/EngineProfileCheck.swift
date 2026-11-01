import Foundation
import WisperCore

enum EngineProfileCheck {
    static func check(_ url: URL) throws -> String {
        let profile = try EngineManifest.loadValidated(from: url)
        return "\(profile.manifest.model.name) · English · \(profile.manifest.acceleration)\nEngine and model hashes verified."
    }
}
