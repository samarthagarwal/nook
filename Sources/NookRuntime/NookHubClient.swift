import Foundation
import HuggingFace

/// Hugging Face Hub client tuned for multi-gigabyte on-device model downloads.
enum NookHubClient {
  /// Shared client — partial downloads are cached by `HubCache` and resume on retry.
  static let shared: HubClient = {
    HubClient(session: URLSession(configuration: NookHubSessionConfig.make()))
  }()

  static func makeSession() -> URLSession {
    URLSession(configuration: NookHubSessionConfig.make())
  }
}
