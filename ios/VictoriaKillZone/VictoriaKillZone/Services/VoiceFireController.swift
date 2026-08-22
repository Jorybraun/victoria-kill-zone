import Combine
import Foundation

#if os(iOS)
@preconcurrency import AVFoundation
@preconcurrency import Speech
#endif

enum VoiceFireUnavailableReason: Equatable, Sendable {
  case speechPermissionDenied
  case microphonePermissionDenied
  case recognizerUnavailable
  case audioInputUnavailable
  case recognitionFailed

  var displayText: String {
    switch self {
    case .speechPermissionDenied: "SPEECH ACCESS DENIED"
    case .microphonePermissionDenied: "MICROPHONE ACCESS DENIED"
    case .recognizerUnavailable: "SPEECH RECOGNIZER UNAVAILABLE"
    case .audioInputUnavailable: "MICROPHONE UNAVAILABLE"
    case .recognitionFailed: "LISTENING INTERRUPTED"
    }
  }
}

enum VoiceFireStatus: Equatable, Sendable {
  case disabled
  case requestingPermission
  case enabled
  case listening(onDevice: Bool)
  case unavailable(VoiceFireUnavailableReason)

  var displayText: String {
    switch self {
    case .disabled: "OFF"
    case .requestingPermission: "REQUESTING PERMISSION"
    case .enabled: "ENABLED • PAUSED"
    case .listening(let onDevice): onDevice ? "LISTENING ON DEVICE" : "LISTENING"
    case .unavailable(let reason): "UNAVAILABLE • \(reason.displayText)"
    }
  }
}

struct VoiceFirePhraseMatcher: Equatable, Sendable {
  static let triggerTokens = ["pew", "pew"]

  func matches(_ transcript: String) -> Bool {
    Self.tokens(in: transcript) == Self.triggerTokens
  }

  static func normalized(_ transcript: String) -> String {
    tokens(in: transcript).joined(separator: " ")
  }

  private static func tokens(in transcript: String) -> [String] {
    let locale = Locale(identifier: "en_US_POSIX")
    return transcript
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
      .lowercased(with: locale)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}

/// Deduplicates partial/final results, imposes a cooldown across recognition tasks,
/// and requires a new recognition generation before another utterance can fire.
struct VoiceFirePhraseGate: Equatable, Sendable {
  let cooldown: TimeInterval
  private(set) var lastAcceptedAt: TimeInterval?
  private(set) var consumedRecognitionGeneration: UInt64?

  init(cooldown: TimeInterval = 0.75) {
    self.cooldown = cooldown
  }

  mutating func shouldFire(
    transcript: String,
    recognitionGeneration: UInt64,
    now: TimeInterval
  ) -> Bool {
    guard VoiceFirePhraseMatcher().matches(transcript) else { return false }
    guard consumedRecognitionGeneration != recognitionGeneration else { return false }
    consumedRecognitionGeneration = recognitionGeneration
    guard let lastAcceptedAt else {
      self.lastAcceptedAt = now
      return true
    }
    guard now - lastAcceptedAt >= cooldown else { return false }
    self.lastAcceptedAt = now
    return true
  }
}

@MainActor
final class VoiceFireController: ObservableObject {
  @Published private(set) var isEnabled = false
  @Published private(set) var status = VoiceFireStatus.disabled
  @Published private(set) var fireRequestSequence: UInt64 = 0

  private var isViewVisible = false
  private var isSceneActive = false
  private var isFireEligible = false
  private var permissionsReady = false
  private var authorizationGeneration: UInt64 = 0
  private var recognitionGeneration: UInt64 = 0
  private var phraseGate = VoiceFirePhraseGate()
  private var restartTask: Task<Void, Never>?

  #if os(iOS)
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-CA"))
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var hasAudioTap = false
  private var didActivateAudioSession = false
  #endif

  deinit {
    restartTask?.cancel()
    #if os(iOS)
    recognitionTask?.cancel()
    if hasAudioTap { audioEngine.inputNode.removeTap(onBus: 0) }
    audioEngine.stop()
    if didActivateAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
  }

  func enable() {
    guard !isEnabled else { return }
    isEnabled = true
    status = .requestingPermission
    authorizationGeneration &+= 1
    requestPermissions(for: authorizationGeneration)
  }

  func disable() {
    authorizationGeneration &+= 1
    isEnabled = false
    permissionsReady = false
    stopListening()
    status = .disabled
  }

  func setViewVisible(_ visible: Bool) {
    isViewVisible = visible
    refreshListeningState()
  }

  func setSceneActive(_ active: Bool) {
    isSceneActive = active
    refreshListeningState()
  }

  func setFireEligible(_ eligible: Bool) {
    isFireEligible = eligible
    refreshListeningState()
  }

  private func requestPermissions(for generation: UInt64) {
    #if os(iOS)
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      requestMicrophonePermission(for: generation)
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { [weak self] result in
        Task { @MainActor [weak self] in
          guard let self, authorizationGeneration == generation, isEnabled else { return }
          if result == .authorized {
            requestMicrophonePermission(for: generation)
          } else {
            status = .unavailable(.speechPermissionDenied)
          }
        }
      }
    case .denied, .restricted:
      status = .unavailable(.speechPermissionDenied)
    @unknown default:
      status = .unavailable(.speechPermissionDenied)
    }
    #else
    status = .unavailable(.recognizerUnavailable)
    #endif
  }

  #if os(iOS)
  private func requestMicrophonePermission(for generation: UInt64) {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      finishAuthorization(generation: generation, granted: true)
    case .undetermined:
      AVAudioApplication.requestRecordPermission { [weak self] granted in
        Task { @MainActor [weak self] in
          self?.finishAuthorization(generation: generation, granted: granted)
        }
      }
    case .denied:
      finishAuthorization(generation: generation, granted: false)
    @unknown default:
      finishAuthorization(generation: generation, granted: false)
    }
  }

  private func finishAuthorization(generation: UInt64, granted: Bool) {
    guard authorizationGeneration == generation, isEnabled else { return }
    guard granted else {
      status = .unavailable(.microphonePermissionDenied)
      return
    }
    permissionsReady = true
    status = .enabled
    refreshListeningState()
  }
  #endif

  private func refreshListeningState() {
    guard isEnabled else {
      stopListening()
      status = .disabled
      return
    }
    guard permissionsReady else { return }
    guard isViewVisible, isSceneActive, isFireEligible else {
      stopListening()
      status = .enabled
      return
    }
    startListeningIfNeeded()
  }

  private func startListeningIfNeeded() {
    #if os(iOS)
    guard recognitionTask == nil, !audioEngine.isRunning else { return }
    guard let recognizer, recognizer.isAvailable else {
      status = .unavailable(.recognizerUnavailable)
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.contextualStrings = ["pew pew"]
    request.taskHint = .dictation
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
      try session.setActive(true)
      didActivateAudioSession = true

      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw VoiceFireAudioError.inputUnavailable
      }
      input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        request.append(buffer)
      }
      hasAudioTap = true
      recognitionRequest = request
      recognitionGeneration &+= 1
      let generation = recognitionGeneration
      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let transcript = result?.bestTranscription.formattedString
        let final = result?.isFinal == true
        Task { @MainActor [weak self] in
          self?.receive(transcript: transcript, isFinal: final, failed: error != nil, generation: generation)
        }
      }
      audioEngine.prepare()
      try audioEngine.start()
      status = .listening(onDevice: request.requiresOnDeviceRecognition)
    } catch {
      stopListening()
      status = .unavailable(error is VoiceFireAudioError ? .audioInputUnavailable : .recognitionFailed)
    }
    #else
    status = .unavailable(.recognizerUnavailable)
    #endif
  }

  private func receive(transcript: String?, isFinal: Bool, failed: Bool, generation: UInt64) {
    guard generation == recognitionGeneration, isEnabled, isFireEligible else { return }
    if let transcript,
      phraseGate.shouldFire(
        transcript: transcript,
        recognitionGeneration: generation,
        now: ProcessInfo.processInfo.systemUptime
      )
    {
      stopListening()
      status = .enabled
      fireRequestSequence &+= 1
      return
    }
    if failed {
      stopListening()
      status = .unavailable(.recognitionFailed)
    } else if isFinal {
      restartAfterFinal()
    }
  }

  private func restartAfterFinal() {
    stopListening()
    status = .enabled
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self?.restartTask = nil
      self?.refreshListeningState()
    }
  }

  private func stopListening() {
    restartTask?.cancel()
    restartTask = nil
    recognitionGeneration &+= 1
    #if os(iOS)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    if hasAudioTap {
      audioEngine.inputNode.removeTap(onBus: 0)
      hasAudioTap = false
    }
    audioEngine.stop()
    if didActivateAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      didActivateAudioSession = false
    }
    #endif
  }
}

private enum VoiceFireAudioError: Error {
  case inputUnavailable
}
