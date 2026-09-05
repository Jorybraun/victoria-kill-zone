import SwiftUI

struct WaitingRoomView: View {
  let room: WaitingRoom
  @ObservedObject var store: LobbyStore

  private var localPlayer: LobbyPlayer? {
    room.localPlayer
  }

  private var opponent: LobbyPlayer? {
    room.players.first { $0.id != room.localPlayerID }
  }

  private var allowsShellStart: Bool {
    #if DEBUG
      return !store.isLiveNetworking
    #else
      return false
    #endif
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("DUEL \(room.code)")
              .font(.title.bold())
            Text(room.localRole == .host ? "HOST" : "GUEST")
              .font(.caption.weight(.semibold).monospaced())
              .foregroundStyle(VKZPalette.telemetry)
          }
          Spacer()
          VKZStatusPill(label: store.networkingStatus, color: VKZPalette.telemetry)
        }

        VKZPanel {
          VStack(spacing: 8) {
            Text(room.localRole == .host ? "SHARE CODE \(room.code)" : "DUEL CODE")
              .font(.caption.weight(.semibold).monospaced())
              .foregroundStyle(VKZPalette.textMuted)
            Text(room.code)
              .font(.system(size: 38, weight: .bold, design: .monospaced))
              .foregroundStyle(VKZPalette.text)
              .accessibilityLabel("Duel code \(room.code)")
          }
          .frame(maxWidth: .infinity)
        }

        #if canImport(UIKit)
          if room.localRole == .host,
            let qrImage = DuelQRCode.image(for: DuelInviteLink.url(for: room.code))
          {
            VKZPanel {
              VStack(spacing: 12) {
                Image(uiImage: qrImage)
                  .interpolation(.none)
                  .resizable()
                  .scaledToFit()
                  .frame(width: 200, height: 200)
                  .padding(8)
                  .background(Color.white)
                  .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                  .accessibilityLabel("QR code to join duel \(room.code)")

                ShareLink(
                  item: DuelInviteLink.url(for: room.code),
                  subject: Text("Pew Pew duel"),
                  message: Text("Join my Pew Pew duel — code \(room.code)")
                ) {
                  Label("TEXT INVITE", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(VKZSecondaryButtonStyle())

                Text("SCAN OR TAP THE LINK TO JOIN")
                  .font(.caption2.weight(.semibold).monospaced())
                  .foregroundStyle(VKZPalette.textMuted)
              }
              .frame(maxWidth: .infinity)
            }
          }
        #endif

        VStack(alignment: .leading, spacing: 10) {
          Text("PLAYERS · \(room.players.count)/\(room.maxPlayers)")
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(VKZPalette.textMuted)

          ForEach(room.players) { player in
            playerRow(player)
          }

          if !room.isFull {
            HStack {
              Image(systemName: "person.badge.clock")
              Text("OPEN SLOT")
              Spacer()
              ProgressView()
            }
            .foregroundStyle(VKZPalette.textMuted)
            .padding(16)
            .background(VKZPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
        }

        if store.isMatchInputLocked {
          VStack(alignment: .leading, spacing: 4) {
            Text("RECONNECTING — INPUT LOCKED")
              .font(.caption.weight(.bold).monospaced())
              .foregroundStyle(VKZPalette.pending)
            if let lastSyncAt = store.lastSyncAt {
              Text("LAST SYNC \(lastSyncAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2.monospaced())
                .foregroundStyle(VKZPalette.textMuted)
            }
          }
        }

        if let localPlayer {
          Button(localPlayer.isReady ? "NOT READY" : "I’M READY") {
            store.toggleReady(for: localPlayer.id, currentValue: localPlayer.isReady)
          }
          .buttonStyle(VKZSecondaryButtonStyle())
          .disabled(store.isBusy || store.isMatchInputLocked)
        }

        #if DEBUG
          shellControls
        #endif

        if room.localRole == .host || allowsShellStart {
          let canStart = room.localRole == .host ? room.canLocalPlayerStart : room.allPlayersReady
          Button(room.localRole == .host ? (room.combatMode == .durableObject ? "ALIGN ARENA" : "START DUEL") : "Simulate Host Start") {
            store.startDuel(as: room.localRole ?? .guest)
          }
          .buttonStyle(VKZPrimaryButtonStyle())
          .disabled(!canStart || store.isBusy || store.isMatchInputLocked)
          .opacity(canStart ? 1 : 0.45)

          if !room.canLocalPlayerStart, room.localRole == .host {
            Text(room.combatMode == .durableObject ? "AT LEAST TWO PLAYERS, ALL READY" : "BOTH PLAYERS MUST BE READY")
              .font(.caption.monospaced())
              .foregroundStyle(VKZPalette.textMuted)
          }
        }

        Button("Leave Lobby", role: .destructive) {
          store.leave()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
      }
      .padding(24)
      .frame(maxWidth: 600)
      .frame(maxWidth: .infinity)
    }
  }

  private func playerRow(_ player: LobbyPlayer) -> some View {
    HStack(spacing: 12) {
      Image(systemName: player.role == .host ? "crown.fill" : "person.fill")
        .foregroundStyle(player.role == .host ? VKZPalette.acquisition : VKZPalette.telemetry)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(player.displayName)
          .font(.headline)
        Text(player.id == room.localPlayerID ? "THIS DEVICE" : player.role.rawValue.uppercased())
          .font(.caption2.monospaced())
          .foregroundStyle(VKZPalette.textMuted)
      }
      Spacer()
      VKZStatusPill(
        label: player.isConnected
          ? (player.isReady ? "READY" : "NOT READY")
          : "DISCONNECTED",
        color: player.isConnected && player.isReady ? VKZPalette.ready : VKZPalette.textMuted
      )
    }
    .padding(14)
    .background(VKZPalette.panel)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  #if DEBUG
    @ViewBuilder
    private var shellControls: some View {
      if !store.isLiveNetworking {
        VStack(alignment: .leading, spacing: 10) {
          Text("LOCAL SHELL CONTROLS")
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(VKZPalette.textMuted)

          if !room.isFull, room.localRole == .host {
            Button("Simulate Opponent Joining") {
              store.simulateOpponentJoined()
            }
            .buttonStyle(VKZSecondaryButtonStyle())
          } else if let opponent {
            Button(opponent.isReady ? "Simulate Opponent Not Ready" : "Simulate Opponent Ready") {
              store.toggleReady(for: opponent.id, currentValue: opponent.isReady)
            }
            .buttonStyle(VKZSecondaryButtonStyle())
          }
        }
      }
    }
  #endif
}
