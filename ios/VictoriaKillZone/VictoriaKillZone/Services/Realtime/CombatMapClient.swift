import Foundation

enum CombatMapError: Error, Equatable {case invalidEndpoint, unavailable, unauthorized, invalidResponse, oversizedMap}

/// Bounded authenticated transfer. A map is private match data and is never
/// persisted in a public cache or exposed through a credential-bearing URL.
struct CombatMapClient: Sendable {
  private let session: URLSession
  init() {
    let configuration=URLSessionConfiguration.ephemeral
    configuration.urlCache=nil; configuration.httpCookieStorage=nil
    configuration.timeoutIntervalForRequest=20; configuration.timeoutIntervalForResource=30
    session=URLSession(configuration:configuration)
  }

  func upload(_ map: DuelFrameMap,ticket: CombatAccessTicket) async throws {
    var request=try Self.request(ticket:ticket,epoch:map.epoch)
    request.httpMethod="PUT"; request.httpBody=map.bytes
    request.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
    request.setValue(String(map.bytes.count),forHTTPHeaderField:"Content-Length")
    let (stream,response)=try await session.bytes(for:request,delegate:CombatMapRedirectPolicy())
    let http=try Self.accepted(response)
    guard http.value(forHTTPHeaderField:"x-vkz-frame-id") == map.frameID else {throw CombatMapError.invalidResponse}
    _ = try await Self.collect(stream,maximum:1024)
  }

  func download(epoch: UInt16,ticket: CombatAccessTicket) async throws -> DuelFrameMap {
    let request=try Self.request(ticket:ticket,epoch:epoch)
    let (stream,response)=try await session.bytes(for:request,delegate:CombatMapRedirectPolicy())
    let http=try Self.accepted(response)
    guard http.mimeType == "application/octet-stream", let hash=http.value(forHTTPHeaderField:"x-vkz-frame-id"),
      hash.count == 64, hash.allSatisfy({$0.isHexDigit}), http.expectedContentLength <= Int64(DuelFrameMap.maximumBytes) else {throw CombatMapError.invalidResponse}
    let bytes=try await Self.collect(stream,maximum:DuelFrameMap.maximumBytes)
    return try DuelFrameMap(epoch:epoch,bytes:bytes,expectedFrameID:hash)
  }

  static func request(ticket: CombatAccessTicket,epoch: UInt16) throws -> URLRequest {
    guard epoch > 0, Int(epoch) == ticket.frameEpoch, ticket.expiresAt > Date(),
      var url=URLComponents(url:ticket.endpoint,resolvingAgainstBaseURL:false), url.scheme == "https",
      url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.hasSuffix("/connect") else {throw CombatMapError.invalidEndpoint}
    url.path=String(url.path.dropLast("connect".count)) + "frames/\(epoch)/map"
    guard let endpoint=url.url else {throw CombatMapError.invalidEndpoint}
    var request=URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData)
    request.setValue("Bearer \(ticket.token)",forHTTPHeaderField:"Authorization")
    return request
  }

  private static func accepted(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http=response as? HTTPURLResponse else {throw CombatMapError.invalidResponse}
    if http.statusCode == 401 || http.statusCode == 403 {throw CombatMapError.unauthorized}
    if http.statusCode == 404 {throw CombatMapError.unavailable}
    guard (200..<300).contains(http.statusCode) else {throw CombatMapError.invalidResponse}
    return http
  }

  private static func collect(_ stream: URLSession.AsyncBytes,maximum: Int) async throws -> Data {
    var bytes=Data(); var chunk=[UInt8](); chunk.reserveCapacity(16_384)
    for try await byte in stream {
      guard !Task.isCancelled else {throw CancellationError()}
      guard bytes.count + chunk.count < maximum else {throw CombatMapError.oversizedMap}
      chunk.append(byte)
      if chunk.count == 16_384 {bytes.append(contentsOf:chunk); chunk.removeAll(keepingCapacity:true)}
    }
    bytes.append(contentsOf:chunk)
    return bytes
  }
}

private final class CombatMapRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
