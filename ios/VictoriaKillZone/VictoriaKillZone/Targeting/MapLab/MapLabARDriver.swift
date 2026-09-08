import Foundation

/// A timeout ends one request, not the camera session. All asynchronous capture
/// paths complete through this owner so an old request can never resume a retry.
@MainActor
final class MapLabCaptureRequest {
  private(set) var activeID: UUID?
  private var continuation: CheckedContinuation<Data, Error>?

  @discardableResult
  func begin(_ id: UUID, continuation: CheckedContinuation<Data, Error>) -> Bool {
    guard activeID == nil else { continuation.resume(throwing: MapLabFailure.notReady); return false }
    activeID = id; self.continuation = continuation
    return true
  }

  func contains(_ id: UUID) -> Bool { activeID == id }

  /// Capture readiness was checked before requesting this immutable map. A
  /// later scan-quality dip cannot erase it, but ending the attempt still can.
  @discardableResult
  func finishArchive(_ result: Result<Data, Error>, request id: UUID, state: MapLabSessionState) -> Bool {
    let completion: Result<Data, Error>
    switch state {
    case .scanning: completion = result
    case .failed(let failure): completion = .failure(failure)
    case .interrupted: completion = .failure(MapLabFailure.interrupted)
    default: completion = .failure(MapLabFailure.notReady)
    }
    return finish(completion, request: id)
  }

  @discardableResult
  func finish(_ result: Result<Data, Error>, request id: UUID) -> Bool {
    guard activeID == id else { return false }
    let pending = continuation
    activeID = nil; continuation = nil
    pending?.resume(with: result)
    return true
  }
}

@MainActor
enum MapLabDriverFactory {
  static func make() -> any MapLabDriving {
    #if os(iOS) && canImport(ARKit)
    return MapLabARDriver()
    #else
    return MapLabUnavailableDriver()
    #endif
  }
}

@MainActor
final class MapLabUnavailableDriver: MapLabDriving {
  private(set) var state: MapLabSessionState = .idle
  var onStateChange: ((MapLabSessionState) -> Void)?
  func startCapture() async throws { try unavailable() }
  func startRecognition(bytes: Data) async throws { try unavailable() }
  func capture() async throws -> Data { throw MapLabFailure.unsupported }
  func stop() async { state = .idle; onStateChange?(state) }
  private func unavailable() throws {
    state = .failed(.unsupported); onStateChange?(state)
    throw MapLabFailure.unsupported
  }
}

#if os(iOS) && canImport(ARKit)
@preconcurrency import ARKit
import AVFoundation
import SceneKit
import SwiftUI

private final class MapLabWorldMapBox: @unchecked Sendable {
  let map: ARWorldMap
  init(_ map: ARWorldMap) { self.map = map }
}

/// A new ARSession for each attempt fences queued delegate callbacks by identity.
/// Only ARWorldTrackingConfiguration is used; no body or reference-image support
/// is needed and this driver cannot submit game state.
@MainActor
final class MapLabARDriver: MapLabDriving {
  private(set) var state: MapLabSessionState = .idle
  var onStateChange: ((MapLabSessionState) -> Void)?
  private(set) var session: ARSession?
  private var delegate: MapLabARDelegate?
  private var policy = MapLabFramePolicy()
  private var generation: UInt64 = 0
  private var frameGeneration: UInt64 = 0
  private var watchdog: Task<Void, Never>?
  private var captureTimeout: Task<Void, Never>?
  private var archiveTasks: [UUID: Task<Void, Never>] = [:]
  private let captureRequest = MapLabCaptureRequest()

  func startCapture() async throws { try await start(bytes: nil) }
  func startRecognition(bytes: Data) async throws {
    guard !bytes.isEmpty, bytes.count <= MapLabBundle.maximumBytes else { throw MapLabFailure.invalidMap }
    try await start(bytes: bytes)
  }

  private func start(bytes: Data?) async throws {
    await stop()
    generation &+= 1; let token = generation
    setState(.starting)
    guard ARWorldTrackingConfiguration.isSupported else {
      setState(.failed(.unsupported)); throw MapLabFailure.unsupported
    }
    let allowed: Bool
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: allowed = true
    case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
    default: allowed = false
    }
    guard token == generation, !Task.isCancelled else { throw CancellationError() }
    guard allowed else { setState(.failed(.cameraDenied)); throw MapLabFailure.cameraDenied }
    let worldMap: MapLabWorldMapBox?
    if let bytes {
      worldMap = try await Task.detached(priority: .userInitiated) {
        guard let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes)
        else { throw MapLabFailure.invalidMap }
        return MapLabWorldMapBox(map)
      }.value
    } else { worldMap = nil }
    guard token == generation, !Task.isCancelled else { throw CancellationError() }
    let current = ARSession()
    let delegate = MapLabARDelegate(owner: self, generation: token)
    current.delegateQueue = .main; current.delegate = delegate
    self.delegate = delegate; session = current
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = [.horizontal, .vertical]
    configuration.initialWorldMap = worldMap?.map
    frameGeneration = policy.begin(bytes == nil ? .capture : .recognition, at: uptime)
    current.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    publishPolicy()
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, self.generation == token else { return }
        self.policy.tick(at: self.uptime); self.publishPolicy()
      }
    }
  }

  func capture() async throws -> Data {
    policy.tick(at: uptime); publishPolicy()
    guard case .scanning(_, true) = state, let session, captureRequest.activeID == nil else { throw MapLabFailure.notReady }
    let token = generation, request = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        guard captureRequest.begin(request, continuation: continuation) else { return }
        captureTimeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
          guard let self, self.generation == token else { return }
          self.finishCapture(.failure(MapLabFailure.timedOut), request: request)
        }
        // ARKit documents completion on delegateQueue, configured above as main.
        session.getCurrentWorldMap { [weak self] map, _ in
          MainActor.assumeIsolated {
            guard let self, self.generation == token, self.captureRequest.contains(request),
              self.archiveTasks[request] == nil else { return }
            guard let map else { self.finishCapture(.failure(MapLabFailure.notReady), request: request); return }
            let box = MapLabWorldMapBox(map)
            self.archiveTasks[request] = Task { [weak self] in
              guard !Task.isCancelled else { self?.archiveTasks[request] = nil; return }
              let result = await Task.detached(priority: .utility) { () -> Result<Data, Error> in
                do {
                  let bytes = try NSKeyedArchiver.archivedData(withRootObject: box.map, requiringSecureCoding: true)
                  guard !bytes.isEmpty, bytes.count <= MapLabBundle.maximumBytes else { throw MapLabFailure.mapTooLarge }
                  return .success(bytes)
                } catch { return .failure(error) }
              }.value
              guard let self else { return }
              self.archiveTasks[request] = nil
              guard self.generation == token, !Task.isCancelled,
                self.captureRequest.contains(request) else { return }
              self.policy.tick(at: self.uptime); self.publishPolicy()
              self.finishCapture(result, request: request, archiveState: self.state)
            }
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.finishCapture(.failure(CancellationError()), request: request)
      }
    }
  }

  func stop() async {
    generation &+= 1
    watchdog?.cancel(); watchdog = nil
    captureTimeout?.cancel(); captureTimeout = nil
    // A timed-out archive may still be finishing secure encoding when another
    // request starts. Keep each owned task until it exits, then await all on stop.
    let pending = Array(archiveTasks.values)
    for task in pending { task.cancel() }
    finishCurrentCapture(.failure(CancellationError()))
    session?.pause(); session?.delegate = nil; session = nil; delegate = nil
    policy.stop(); setState(.idle)
    for task in pending { await task.value }
  }

  func reassertDelegate() { session?.delegateQueue = .main; session?.delegate = delegate }

  fileprivate func receive(_ frame: ARFrame, from current: ARSession, generation token: UInt64) {
    guard token == generation, current === session else { return }
    let now = uptime
    let tracking: MapLabFrameTracking
    switch frame.camera.trackingState {
    case .normal: tracking = .normal
    case .notAvailable: tracking = .unavailable
    case .limited(let reason):
      switch reason {
      case .relocalizing: tracking = .relocalizing
      case .excessiveMotion: tracking = .limited(.moveSlowly)
      case .insufficientFeatures: tracking = .limited(.findDetail)
      default: tracking = .limited(.starting)
      }
    }
    // ARFrame timestamps are seconds since boot. Preserve capture time even if
    // both delegate delivery and currentFrame stall; receipt time is not evidence
    // that the camera is still tracking the saved surroundings.
    policy.receive(MapLabFrameSample(timestamp: frame.timestamp, capturedAt: frame.timestamp,
      tracking: tracking, usableMap: [.extending, .mapped].contains(frame.worldMappingStatus)),
      generation: frameGeneration, at: now)
    publishPolicy()
  }

  fileprivate func interrupted(from current: ARSession, generation token: UInt64) {
    guard token == generation, current === session else { return }
    policy.interrupt(); publishPolicy()
  }

  private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
  private func setState(_ next: MapLabSessionState) {
    guard state != next else { return }
    state = next; onStateChange?(next)
  }
  private func publishPolicy() {
    setState(policy.state)
    switch policy.state {
    case .failed(let failure):
      watchdog?.cancel(); watchdog = nil
      session?.pause(); finishCurrentCapture(.failure(failure))
    case .interrupted:
      watchdog?.cancel(); watchdog = nil
      session?.pause(); finishCurrentCapture(.failure(MapLabFailure.interrupted))
    default: break
    }
  }
  private func finishCurrentCapture(_ result: Result<Data, Error>) {
    guard let request = captureRequest.activeID else { return }
    finishCapture(result, request: request)
  }
  private func finishCapture(_ result: Result<Data, Error>, request: UUID, archiveState: MapLabSessionState? = nil) {
    let finished: Bool
    if let archiveState { finished = captureRequest.finishArchive(result, request: request, state: archiveState) }
    else { finished = captureRequest.finish(result, request: request) }
    guard finished else { return }
    captureTimeout?.cancel(); captureTimeout = nil
    archiveTasks[request]?.cancel()
  }
}

/// ARKit delivers these callbacks only on the explicitly configured main queue.
private final class MapLabARDelegate: NSObject, ARSessionDelegate {
  private weak var owner: MapLabARDriver?
  private let generation: UInt64
  @MainActor init(owner: MapLabARDriver, generation: UInt64) { self.owner = owner; self.generation = generation }
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    MainActor.assumeIsolated { owner?.receive(frame, from: session, generation: generation) }
  }
  func sessionWasInterrupted(_ session: ARSession) {
    MainActor.assumeIsolated { owner?.interrupted(from: session, generation: generation) }
  }
  func session(_ session: ARSession, didFailWithError error: Error) {
    MainActor.assumeIsolated { owner?.interrupted(from: session, generation: generation) }
  }
  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
}

struct MapLabCameraPreview: UIViewRepresentable {
  let driver: MapLabARDriver
  func makeUIView(context: Context) -> ARSCNView {
    let view = ARSCNView(frame: .zero)
    view.scene = SCNScene(); view.backgroundColor = .black
    view.automaticallyUpdatesLighting = false
    updateUIView(view, context: context)
    return view
  }
  func updateUIView(_ view: ARSCNView, context: Context) {
    if let session = driver.session, view.session !== session { view.session = session }
    driver.reassertDelegate()
  }
  static func dismantleUIView(_ view: ARSCNView, coordinator: Void) { view.session = ARSession() }
}
#endif
