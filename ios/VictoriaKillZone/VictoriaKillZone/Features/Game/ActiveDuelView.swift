import SwiftUI

struct ActiveDuelView: View {
  let duel: ActiveDuel
  @ObservedObject var store: LobbyStore

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [VKZPalette.background, VKZPalette.surfaceRaised],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      TimelineView(.periodic(from: .now, by: 0.2)) { context in
        ScrollView {
          VStack(spacing: 24) {
            topTelemetry(at: context.date)
            connectionBanner
            opponentPanel
            Spacer(minLength: 48)
            debugControl
            latestEvent
            Button("LEAVE DUEL", role: .destructive) {
              store.leave()
            }
            .buttonStyle(VKZSecondaryButtonStyle())
          }
          .padding(20)
          .frame(maxWidth: 600)
          .frame(maxWidth: .infinity)
          .opacity(store.isMatchInputLocked ? 0.58 : 1)
        }
      }
    }
  }

  private func topTelemetry(at date: Date) -> some View {
    HStack(alignment: .top) {
      telemetryBlock(
        label: "HEALTH",
        value: String(duel.localPlayer?.health ?? 0),
        color: VKZPalette.ready
      )
      Spacer()
      VStack(spacing: 4) {
        Text(phaseTitle)
          .font(.caption.weight(.bold).monospaced())
          .foregroundStyle(VKZPalette.telemetry)
        if duel.phase == .countdown {
          Text(String(countdownValue(at: date)))
            .font(.system(size: 38, weight: .bold, design: .monospaced))
            .accessibilityLabel("Duel starts in \(countdownValue(at: date))")
        }
      }
      Spacer()
      telemetryBlock(
        label: "AMMO",
        value: "\(duel.localPlayer?.ammo ?? 0) / 8",
        color: .white
      )
    }
  }

  @ViewBuilder
  private var connectionBanner: some View {
    if store.isMatchInputLocked {
      VKZPanel {
        VStack(spacing: 4) {
          Text("RECONNECTING — INPUT LOCKED")
            .font(.headline.monospaced())
            .foregroundStyle(VKZPalette.pending)
          if let lastSyncAt = store.lastSyncAt {
            Text("LAST SYNC \(lastSyncAt.formatted(date: .omitted, time: .standard))")
              .font(.caption.monospaced())
              .foregroundStyle(VKZPalette.textMuted)
          }
        }
        .frame(maxWidth: .infinity)
      }
    } else if store.syncStatus == .restored {
      VKZStatusPill(label: "STATE VERIFIED", color: VKZPalette.ready)
    }
  }

  private var opponentPanel: some View {
    VKZPanel {
      VStack(spacing: 12) {
        Text(duel.opponent?.displayName.uppercased() ?? "OPPONENT")
          .font(.headline.monospaced())
        Text("\(duel.opponent?.health ?? 0) / 100")
          .font(.system(size: 42, weight: .bold, design: .monospaced))
          .foregroundStyle(VKZPalette.danger)
        ProgressView(value: Double(duel.opponent?.health ?? 0), total: 100)
          .tint(VKZPalette.danger)
        Text("OPPONENT HEALTH")
          .font(.caption.monospaced())
          .foregroundStyle(VKZPalette.textMuted)
      }
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Opponent health, \(duel.opponent?.health ?? 0) of 100"
      )
    }
  }

  @ViewBuilder
  private var debugControl: some View {
    switch duel.phase {
    case .countdown:
      Text("DUEL STARTS IN")
        .font(.headline.monospaced())
        .foregroundStyle(VKZPalette.pending)
    case .running where duel.localRole == .host:
      VStack(spacing: 8) {
        Button(debugButtonLabel) {
          store.debugFire()
        }
        .buttonStyle(VKZPrimaryButtonStyle())
        .disabled(!store.canDebugFire)
        .accessibilityLabel("Debug fire, torso test, 34 damage")
        Text(debugHelper)
          .font(.caption.weight(.semibold).monospaced())
          .foregroundStyle(VKZPalette.textMuted)
      }
    case .running:
      Text("AWAITING TEST SHOT")
        .font(.headline.monospaced())
        .foregroundStyle(VKZPalette.textMuted)
    case .finished:
      Text("DUEL COMPLETE")
        .font(.title.bold())
    case .cancelled:
      Text("DUEL CANCELLED")
        .font(.title.bold())
    case .lobby:
      EmptyView()
    }
  }

  @ViewBuilder
  private var latestEvent: some View {
    if let event = duel.events.first {
      Text(event.message)
        .font(.callout.monospaced())
        .foregroundStyle(VKZPalette.textMuted)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.updatesFrequently)
    }
  }

  private var debugButtonLabel: String {
    switch store.debugShotState {
    case .pending: "SHOT PENDING…"
    case .confirmed(let damage): "HIT CONFIRMED • \(damage)"
    case .idle, .failed: "DEBUG FIRE"
    }
  }

  private var debugHelper: String {
    switch store.debugShotState {
    case .confirmed: "STATE VERIFIED"
    case .idle, .pending, .failed: "TORSO TEST • 34 DAMAGE"
    }
  }

  private var phaseTitle: String {
    switch duel.phase {
    case .lobby: "WAITING"
    case .countdown: "DUEL STARTS IN"
    case .running: "NETWORK TEST"
    case .finished: "DUEL COMPLETE"
    case .cancelled: "DUEL CANCELLED"
    }
  }

  private func countdownValue(at date: Date) -> Int {
    guard let startsAt = duel.startsAt else { return 0 }
    let elapsedMilliseconds = max(0, date.timeIntervalSince(duel.syncedAt) * 1_000)
    let estimatedServerNow = duel.serverNow + elapsedMilliseconds
    return max(0, Int(ceil((startsAt - estimatedServerNow) / 1_000)))
  }

  private func telemetryBlock(label: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2.weight(.semibold).monospaced())
        .foregroundStyle(VKZPalette.textMuted)
      Text(value)
        .font(.title3.bold().monospacedDigit())
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
  }
}
