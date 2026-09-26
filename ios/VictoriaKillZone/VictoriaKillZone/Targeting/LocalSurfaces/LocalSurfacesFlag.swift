import Foundation

enum LocalSurfacesFlag {
  static let launchArgument = "-VKZLocalSurfaces"
  static let defaultsKey = "vkz.localSurfaces.enabled"

  /// Default off. Debug-only opt-in: launch argument or UserDefaults key; never user-visible.
  static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments,
    defaults: UserDefaults = .standard) -> Bool {
    arguments.contains(launchArgument) || defaults.bool(forKey: defaultsKey)
  }
}
