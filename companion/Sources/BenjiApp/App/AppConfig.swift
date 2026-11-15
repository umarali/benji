import Foundation
import BenjiCore

enum AppConfig {
    /// Folder containing the `benji` Python package. Override with $BENJI_DIR; otherwise it is
    /// found from where the app bundle sits (see `AssistantLocator`).
    static let assistantDir = AssistantLocator.resolve(
        environment: ProcessInfo.processInfo.environment,
        bundleURL: Bundle.main.bundleURL,
        executableURL: Bundle.main.executableURL,
        currentDirectory: FileManager.default.currentDirectoryPath)

    static let idleSize = CGSize(width: 240, height: 44)
    static let expandedSize = CGSize(width: 460, height: 380)
}
