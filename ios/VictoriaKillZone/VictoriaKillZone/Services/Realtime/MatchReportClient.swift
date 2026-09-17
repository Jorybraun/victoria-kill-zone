import Foundation

/// Bounded player problem report posted to the combat worker's report route.
struct MatchReport: Encodable, Sendable {
  struct Device: Encodable, Sendable {
    var model: String
    var ios: String
    var build: String
  }
  var device: Device
  var transcript: String
  var log: [DuelFrameDiagnosticEvent]
}

enum MatchReportError: Error, Equatable {
  case invalidEndpoint, rejected, invalidResponse
}

/// Uploads a match report against the ticket's match-scoped report route.
@MainActor
final class MatchReportClient {
  private let session: URLSession

  init(session: URLSession = .shared) {self.session = session}

  /// The ticket endpoint is `…/v1/matches/:id/connect`; the report route is its sibling.
  func reportURL(ticket: CombatAccessTicket) -> URL? {
    let base = ticket.endpoint.deletingLastPathComponent()
    guard base.scheme == "https" else {return nil}
    return base.appendingPathComponent("report")
  }

  func send(_ report: MatchReport, ticket: CombatAccessTicket) async throws -> URL {
    guard ticket.expiresAt > Date(), let url = reportURL(ticket: ticket) else {
      throw MatchReportError.invalidEndpoint
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(ticket.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(report)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      let body = try? JSONDecoder().decode([String: String].self, from: data),
      let link = body["url"], let issueURL = URL(string: link) else {
      throw MatchReportError.rejected
    }
    return issueURL
  }
}
