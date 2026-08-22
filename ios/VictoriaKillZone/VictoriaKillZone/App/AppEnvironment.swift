import Foundation

struct AppEnvironment: Sendable {
  let gameSessionClient: any GameSessionClient
  let targetingSession: any TargetingSession

  static let phaseZeroShell = AppEnvironment(
    gameSessionClient: UnavailableGameSessionClient(),
    targetingSession: UnavailableTargetingSession()
  )

  static func liveOrShell(bundle: Bundle = .main) -> AppEnvironment {
    guard
      let rawValue = bundle.object(forInfoDictionaryKey: "CONVEX_DEPLOYMENT_URL") as? String,
      let deploymentURL = validatedDeploymentURL(rawValue)
    else {
      return .phaseZeroShell
    }

    return AppEnvironment(
      gameSessionClient: ConvexGameSessionClient(deploymentURL: deploymentURL),
      targetingSession: TargetingSessionFactory.liveOrUnavailable()
    )
  }

  static func live(deploymentURL: String) -> AppEnvironment? {
    guard let deploymentURL = validatedDeploymentURL(deploymentURL) else { return nil }
    return AppEnvironment(
      gameSessionClient: ConvexGameSessionClient(deploymentURL: deploymentURL),
      targetingSession: TargetingSessionFactory.liveOrUnavailable()
    )
  }

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
