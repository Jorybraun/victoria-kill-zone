import Foundation

struct AppEnvironment: Sendable {
  static let deploymentURLKey = "CONVEX_DEPLOYMENT_URL"

  let gameSessionClient: any GameSessionClient
  let targetingSession: any TargetingSession

  static let phaseZeroShell = AppEnvironment(
    gameSessionClient: UnavailableGameSessionClient(),
    targetingSession: UnavailableTargetingSession()
  )

  static func liveOrShell(
    bundle: Bundle = .main,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> AppEnvironment {
    let targetingSession = makeLiveTargetingSession()
    let bundleValue = bundle.object(forInfoDictionaryKey: deploymentURLKey) as? String
    guard
      let deploymentURL = configuredDeploymentURL(
        bundleValue: bundleValue,
        environmentValue: environment[deploymentURLKey]
      )
    else {
      return AppEnvironment(
        gameSessionClient: UnavailableGameSessionClient(),
        targetingSession: targetingSession
      )
    }

    return AppEnvironment(
      gameSessionClient: ConvexGameSessionClient(deploymentURL: deploymentURL),
      targetingSession: targetingSession
    )
  }

  static func live(deploymentURL: String) -> AppEnvironment? {
    guard let deploymentURL = validatedDeploymentURL(deploymentURL) else { return nil }
    return AppEnvironment(
      gameSessionClient: ConvexGameSessionClient(deploymentURL: deploymentURL),
      targetingSession: makeLiveTargetingSession()
    )
  }

  private static func makeLiveTargetingSession() -> any TargetingSession {
    #if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
      ARVisionTargetingSession()
    #else
      UnavailableTargetingSession()
    #endif
  }

  /// Xcode scheme environments can override the Info.plist build-setting value.
  /// Invalid or absent values deliberately retain the safe networking shell.
  static func configuredDeploymentURL(
    bundleValue: String?,
    environmentValue: String?
  ) -> String? {
    [environmentValue, bundleValue]
      .compactMap { $0 }
      .compactMap(validatedDeploymentURL)
      .first
  }

  static func validatedDeploymentURL(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("$("),
      let components = URLComponents(string: trimmed),
      components.scheme == "https", components.host != nil
    else {
      return nil
    }
    return trimmed
  }
}
