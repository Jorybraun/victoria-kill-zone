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
    case .speechPermissionDenied:
      "SPEECH ACCESS DENIED"
    case .microphonePermissionDenied:
      "MICROPHONE ACCESS DENIED"
    case .recognizerUnavailable:
      "SPEECH RECOGNIZER UNAVAILABLE"
    case .audioInputUnavailable:
      "MICROPHONE UNAVAILABLE"
    case .recognitionFailed:
      "LISTENING INTERRUPTED"
    }
  }

  var accessibilityText: String {
    switch self {
    case .speechPermissionDenied:
      "Speech recognition permission was not granted."
    case .microphonePermissionDenied:
      "Microphone permission was not granted."
    case .recognizerUnavailable:
      "Speech recognition is currently unavailable."
    case .audioInputUnavailable:
      "The microphone is currently unavailable."
    case .recognitionFailed:
      "Voice listening was interrupted. Turn Voice Fire off and on to retry."
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
    case .disabled:
      "OFF"
    case .requestingPermission:
      "REQUESTING PERMISSION"
    case .enabled:
      "ENABLED • PAUSED"
    case .listening(let onDevice):
      onDevice ? "LISTENING ON DEVICE" : "LISTENING"
    case .unavailable(let reason):
      "UNAVAILABLE • \(reason.displayText)"
    }
  }

  var accessibilityText: String {
    switch self {
    case .disabled:
      "Voice Fire is off."
    case .requestingPermission:
      "Voice Fire is requesting permission."
    case .enabled:
      "Voice Fire is enabled and paused until firing is available."
    case .listening(let onDevice):
      onDevice
        ? "Voice Fire is listening on this device. Say pew pew to fire."
        : "Voice Fire is listening. Say pew pew to fire."
    case .unavailable(let reason):
      "Voice Fire is unavailable. \(reason.accessibilityText)"
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
    let folded = transcript
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posixLocale)
      .lowercased(with: posixLocale)

    return folded
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  private static let posixLocale = Locale(identifier: "en_US_POSIX")
}

/// Prevents a partial result and its final transcript (or a rapid task restart)
/// from turning one spoken phrase into multiple fire requests.
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

    // A matching generation is consumed even during cooldown so a delayed final
    // result cannot fire after the cooldown expires.
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
    if hasAudioTap {
      audioEngine.inputNode.removeTap(onBus: 0)
    }
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
    restartTask?.cancel()
    restartTask = nil
    stopListening()
    status = .disabled
  }

  func setViewVisible(_ isVisible: Bool) {
    isViewVisible = isVisible
    refreshListeningState()
  }

  func setSceneActive(_ isActive: Bool) {
    isSceneActive = isActive
    refreshListeningState()
  }

  func setFireEligible(_ isEligible: Bool) {
    isFireEligible = isEligible
    refreshListeningState()
  }

  private func requestPermissions(for generation: UInt64) {
#if os(iOS)
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      requestMicrophonePermission(for: generation)
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { [weak self] authorizationStatus in
        Task { @MainActor [weak self] in
          guard let self, self.authorizationGeneration == generation, self.isEnabled else { return }
          if authorizationStatus == .authorized {
            self.requestMicrophonePermission(for: generation)
          } else {
            self.permissionsReady = false
            self.status = .unavailable(.speechPermissionDenied)
          }
        }
      }
    case .denied, .restricted:
      permissionsReady = false
      status = .unavailable(.speechPermissionDenied)
    @unknown default:
      permissionsReady = false
      status = .unavailable(.speechPermissionDenied)
    }
#else
    permissionsReady = false
    status = .unavailable(.recognizerUnavailable)
#endif
  }

#if os(iOS)
  private func requestMicrophonePermission(for generation: UInt64) {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      finishAuthorization(for: generation, microphoneGranted: true)
    case .undetermined:
      AVAudioApplication.requestRecordPermission { [weak self] isGranted in
        Task { @MainActor [weak self] in
          self?.finishAuthorization(for: generation, microphoneGranted: isGranted)
        }
      }
    case .denied:
      finishAuthorization(for: generation, microphoneGranted: false)
    @unknown default:
      finishAuthorization(for: generation, microphoneGranted: false)
    }
  }

  private func finishAuthorization(for generation: UInt64, microphoneGranted: Bool) {
    guard authorizationGeneration == generation, isEnabled else { return }
    guard microphoneGranted else {
      permissionsReady = false
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

    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.defaultToSpeaker, .mixWithOthers]
      )
      try audioSession.setActive(true)
      didActivateAudioSession = true

      let inputNode = audioEngine.inputNode
      let recordingFormat = inputNode.outputFormat(forBus: 0)
      guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
        throw VoiceFireAudioError.inputUnavailable
      }

      inputNode.installTap(
        onBus: 0,
        bufferSize: 1_024,
        format: recordingFormat
      ) { buffer, _ in
        request.append(buffer)
      }
      hasAudioTap = true
      recognitionRequest = request
      recognitionGeneration &+= 1
      let generation = recognitionGeneration

      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let transcript = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal == true
        let didFail = error != nil
        Task { @MainActor [weak self] in
          self?.receiveRecognition(
            transcript: transcript,
            isFinal: isFinal,
            didFail: didFail,
            generation: generation
          )
        }
      }

      audioEngine.prepare()
      try audioEngine.start()
      status = .listening(onDevice: request.requiresOnDeviceRecognition)
    } catch {
      stopListening()
      status = .unavailable(
        error is VoiceFireAudioError ? .audioInputUnavailable : .recognitionFailed
      )
    }
#else
    status = .unavailable(.recognizerUnavailable)
#endif
  }

  private func receiveRecognition(
    transcript: String?,
    isFinal: Bool,
    didFail: Bool,
    generation: UInt64
  ) {
    guard generation == recognitionGeneration, isEnabled, isFireEligible else { return }

    if let transcript,
      phraseGate.shouldFire(
        transcript: transcript,
        recognitionGeneration: generation,
        now: ProcessInfo.processInfo.systemUptime
      )
    {
      // End capture before publishing the request. The view rechecks LobbyStore
      // eligibility and then uses the same debugFire() path as the button.
      stopListening()
      status = .enabled
      fireRequestSequence &+= 1
      return
    }

    if didFail {
      stopListening()
      status = .unavailable(.recognitionFailed)
    } else if isFinal {
      restartRecognitionAfterFinalResult()
    }
  }

  private func restartRecognitionAfterFinalResult() {
    stopListening()
    status = .enabled
    restartTask?.cancel()
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
