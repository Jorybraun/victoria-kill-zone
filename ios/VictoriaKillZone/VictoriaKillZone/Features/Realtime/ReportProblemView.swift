import AVFoundation
import Speech
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Match-menu problem report: record or type what went wrong and upload it with
/// the persisted setup log and device metadata. Creates a labeled GitHub issue
/// via the combat worker, which a Devin session then triages.
struct ReportProblemView: View {
  let ticket: CombatAccessTicket?
  let loadLog: () throws -> [DuelFrameDiagnosticEvent]
  var onDismiss: () -> Void = {}

  @State private var transcript = ""
  @State private var state: ReportState = .idle
  @State private var recorder: AVAudioRecorder?
  @State private var recognizer = SFSpeechRecognizer()
  @State private var issueURL: URL?

  enum ReportState: Equatable {case idle, recording, transcribing, sending, sent, failed(String)}

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("Describe what went wrong. The match setup log is attached automatically — no player names or locations are included.")
          .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
        TextEditor(text: $transcript)
          .frame(minHeight: 120)
          .scrollContentBackground(.hidden)
          .background(VKZPalette.panel)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .disabled(state == .sent)
        recordControls
        if let issueURL {
          Link("Report filed — view status", destination: issueURL)
            .font(.subheadline)
        }
        if case .failed(let message) = state {
          Text(message).font(.subheadline).foregroundStyle(VKZPalette.danger)
        }
        Spacer()
        sendButton
      }
      .padding(20)
      .background(VKZPalette.background.ignoresSafeArea())
      .navigationTitle("Report a problem")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onDismiss)
        }
      }
    }
  }

  @ViewBuilder private var recordControls: some View {
    switch state {
    case .recording:
      Button("Stop & transcribe", action: stopRecording).buttonStyle(VKZSecondaryButtonStyle())
    case .transcribing:
      HStack(spacing: 8) {ProgressView().tint(.white); Text("Transcribing…").foregroundStyle(VKZPalette.textMuted)}
    default:
      Button("Record voice note", action: startRecording).buttonStyle(VKZSecondaryButtonStyle())
    }
  }

  private var sendButton: some View {
    Button {
      Task {await send()}
    } label: {
      HStack(spacing: 8) {
        if state == .sending {ProgressView().tint(VKZPalette.background)}
        Text(state == .sent ? "Report sent" : state == .sending ? "Sending…" : "Send report")
          .frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(VKZPrimaryButtonStyle())
    .disabled(!canSend)
  }

  private var canSend: Bool {
    ticket != nil && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && ![.recording, .transcribing, .sending, .sent].contains(state)
  }

  private func startRecording() {
    Task {
      guard await AVAudioApplication.requestRecordPermission(),
        await withCheckedContinuation({ (cont: CheckedContinuation<Bool, Never>) in
          SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }) else {
        state = .failed("Microphone or speech access was not allowed. You can still type your report.")
        return
      }
      do {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vkz-report-\(UUID().uuidString).m4a")
        recorder = try AVAudioRecorder(url: url, settings: [
          AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        ])
        recorder?.record()
        state = .recording
      } catch { state = .failed("Couldn't start recording — type your report instead.") }
    }
  }

  private func stopRecording() {
    recorder?.stop()
    state = .transcribing
    guard let url = recorder?.url, let recognizer, recognizer.isAvailable else {
      state = .idle
      return
    }
    recognizer.recognitionTask(with: SFSpeechURLRecognitionRequest(url: url)) { result, error in
      Task { @MainActor in
        if let text = result?.bestTranscription.formattedString, !text.isEmpty {
          transcript = transcript.isEmpty ? text : "\(transcript) \(text)"
        }
        if result?.isFinal == true || error != nil {state = .idle}
      }
    }
  }

  private func send() async {
    guard let ticket else {return}
    state = .sending
    do {
      #if os(iOS)
      let device = MatchReport.Device(model: UIDevice.current.model, ios: UIDevice.current.systemVersion,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
      #else
      let device = MatchReport.Device(model: "Mac", ios: ProcessInfo.processInfo.operatingSystemVersionString,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
      #endif
      let report = MatchReport(device: device,
        transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
        log: (try? loadLog()) ?? [])
      issueURL = try await MatchReportClient().send(report, ticket: ticket)
      state = .sent
    } catch {
      state = .failed("Couldn't send the report — check your connection and try again.")
    }
  }
}
