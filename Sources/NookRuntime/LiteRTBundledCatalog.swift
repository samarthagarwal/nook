import Foundation
import NookCore

/// LiteRT-LM weights that ship inside the app bundle for the Bundled tier.
enum LiteRTBundledCatalog {
    static let filename = "qwen3_0.6b_nothink_q4_block32_ekv1280.litertlm"
    static let repoId = "litert-community/Qwen3-0.6B-int4"

    /// Directory name under `Resources/BundledModels/`.
    private static let subdirectory = "BundledModels/LiteRT"

    /// URL of the shipped `.litertlm` inside `Bundle.module`, if present and non-trivial.
    static var bundledFileURL: URL? {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        // Prefer nested folder layout: BundledModels/LiteRT/<file>
        // (Package.swift copies `Resources/BundledModels` into the module bundle.)
        if let url = Bundle.module.url(
            forResource: base,
            withExtension: ext,
            subdirectory: subdirectory
        ), isPlausibleModelFile(url) {
            return url
        }
        // Fallback: file directly under BundledModels/
        if let url = Bundle.module.url(
            forResource: base,
            withExtension: ext,
            subdirectory: "BundledModels"
        ), isPlausibleModelFile(url) {
            return url
        }
        // Fallback: LiteRT/<file> without BundledModels prefix (some SPM layouts flatten).
        if let url = Bundle.module.url(
            forResource: base,
            withExtension: ext,
            subdirectory: "LiteRT"
        ), isPlausibleModelFile(url) {
            return url
        }
        return nil
    }

    static var isAvailable: Bool {
        bundledFileURL != nil
    }

    /// Ensures Application Support has a usable copy (or symlink target) of the bundled file.
    /// Returns the local path LiteRT should load.
    @discardableResult
    static func materializeIntoApplicationSupport() throws -> URL {
        let destination = LiteRTModelPaths.localFileURL(repoId: repoId, filename: filename)
        if LiteRTModelPaths.isDownloaded(repoId: repoId, filename: filename) {
            return destination
        }
        guard let source = bundledFileURL else {
            throw LiteRTModelRuntimeError.modelNotReady(underlying: nil)
        }
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        print("[LiteRT] Materialized bundled model → \(destination.lastPathComponent)")
        return destination
    }

    private static func isPlausibleModelFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return size > 64 * 1024 * 1024
    }
}
