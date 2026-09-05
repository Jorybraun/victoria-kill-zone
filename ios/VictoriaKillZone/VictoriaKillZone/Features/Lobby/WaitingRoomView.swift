import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct WaitingRoomView: View {
  let room: WaitingRoom
  @ObservedObject var store: LobbyStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showQRCode = false
  @State private var copiedCode = false

  private var localPlayer: LobbyPlayer? {room.localPlayer}
  private var opponent: LobbyPlayer? {room.players.first {$0.id != room.localPlayerID}}
  private var isArena: Bool {room.combatMode == .durableObject}
  private var matchName: String {isArena ? "Arena" : "Classic duel"}
  private var spokenCode: String {room.code.map(String.init).joined(separator: " ")}
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
        VStack(alignment: .leading, spacing: 10) {
          Text("\(matchName) lobby").font(.title.bold()).accessibilityAddTraits(.isHeader)
          Label(room.localRole == .host ? "You’re hosting" : "You’ve joined",
            systemImage: room.localRole == .host ? "crown.fill" : "person.fill")
            .font(.subheadline.weight(.semibold)).foregroundStyle(VKZPalette.telemetry)
          rulesSummary
        }

        inviteSummary
        roster

        if store.isMatchInputLocked {
          Label("Reconnecting. Ready and start controls return when the lobby is synchronized.", systemImage: "wifi.exclamationmark")
            .font(.subheadline.weight(.semibold)).foregroundStyle(VKZPalette.pending)
            .fixedSize(horizontal: false, vertical: true)
        }

        #if canImport(UIKit) && canImport(Network)
        if store.isLiveNetworking && !isArena {
          Label("Allow Local Network access when prompted so nearby players can connect.", systemImage: "wifi")
            .font(.footnote).foregroundStyle(VKZPalette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        #endif

        if dynamicTypeSize.isAccessibilitySize {readyControls}

        #if canImport(UIKit)
        if room.localRole == .host {qrInvite}
        #endif

        #if DEBUG
        shellControls
        #endif

        Button("Leave lobby", role: .destructive) {store.leave()}
          .frame(maxWidth: .infinity, minHeight: 44)
          .disabled(store.operation == .leaving)
      }
      .padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !dynamicTypeSize.isAccessibilitySize {
        readyControls.padding(.horizontal, 20).padding(.vertical, 12)
          .frame(maxWidth: 600).frame(maxWidth: .infinity)
          .background(VKZPalette.background.opacity(0.98))
          .overlay(alignment: .top) {VKZPalette.border.frame(height: 1)}
      }
    }
    .onAppear {
      #if canImport(Network)
      if store.isLiveNetworking && !isArena {
        ArenaPeerLink.primeLocalNetworkPermission()
      }
      #endif
    }
  }

  private var rulesSummary: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(isArena ? "\(room.maxPlayers == 2 ? "2" : "2–\(room.maxPlayers)") players · Shared play area" : "\(room.maxPlayers) players · Classic mode")
      if let duration = store.lobbyRoundDurationMs {
        let seconds = max(0, duration / 1000)
        Text(String(format: "%d:%02d per round", seconds / 60, seconds % 60))
          .monospacedDigit()
      }
    }
    .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
    .accessibilityElement(children: .combine)
  }

  private var inviteSummary: some View {
    VKZPanel {
      VStack(alignment: .leading, spacing: 10) {
        Text(room.localRole == .host ? "INVITE WITH THIS CODE" : "\(matchName.uppercased()) CODE")
          .font(.caption.weight(.semibold).monospaced()).foregroundStyle(VKZPalette.textMuted)
        HStack(spacing: 10) {
          Text(room.code).font(.system(.title, design: .monospaced, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            .textSelection(.enabled)
            .accessibilityLabel("\(matchName) code, \(spokenCode)")
          Spacer(minLength: 0)
          #if canImport(UIKit)
          Button {
            UIPasteboard.general.string = room.code
            copiedCode = true
            UIAccessibility.post(notification: .announcement, argument: "\(matchName) code copied")
          } label: {
            Image(systemName: copiedCode ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44)
          }
          .buttonStyle(.plain).foregroundStyle(VKZPalette.telemetry)
          .accessibilityLabel(copiedCode ? "Code copied. Copy again" : "Copy \(matchName.lowercased()) code")
          #endif
        }
        if room.localRole == .host {
          ShareLink(item: DuelInviteLink.url(for: room.code), subject: Text("Pew Pew \(matchName.lowercased())"),
            message: Text("Join my Pew Pew \(matchName.lowercased()) — code \(room.code)")) {
            Label("Share invite", systemImage: "square.and.arrow.up")
              .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
          }
          .foregroundStyle(VKZPalette.telemetry)
          .accessibilityLabel("Share invite to this \(matchName.lowercased())")
        }
      }
    }
  }

  private var roster: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("PLAYERS").font(.caption.weight(.semibold).monospaced())
        Spacer()
        Text("\(room.players.count) / \(room.maxPlayers)").font(.subheadline.bold().monospacedDigit())
      }
      .foregroundStyle(VKZPalette.textMuted)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(room.players.count) of \(room.maxPlayers) player slots filled")
      ForEach(room.players) {player in playerRow(player)}
      if !room.isFull {
        let available = room.maxPlayers - room.players.count
        Label("\(available) open \(available == 1 ? "slot" : "slots")", systemImage: "person.badge.plus")
          .font(.subheadline).foregroundStyle(VKZPalette.textMuted)
          .padding(.horizontal, 14).padding(.vertical, 6)
      }
    }
  }

  private var readyControls: some View {
    VStack(spacing: 10) {
      Text(readinessGuidance).font(.subheadline).foregroundStyle(VKZPalette.textMuted)
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
      if let localPlayer {
        Button {
          store.toggleReady(for: localPlayer.id, currentValue: localPlayer.isReady)
        } label: {
          HStack(spacing: 8) {
            if store.operation == .settingReady {ProgressView().tint(.white)}
            Label(localPlayer.isReady ? "Ready · tap to change" : "I’m ready",
              systemImage: localPlayer.isReady ? "checkmark.circle.fill" : "circle")
          }
        }
        .buttonStyle(VKZSecondaryButtonStyle()).disabled(store.isBusy || store.isMatchInputLocked)
        .accessibilityLabel(localPlayer.isReady ? "Ready. Mark me not ready" : "Mark me ready")
      }
      if room.localRole == .host || allowsShellStart {
        let canStart = room.localRole == .host ? room.canLocalPlayerStart : room.allPlayersReady
        Button {store.startDuel(as: room.localRole ?? .guest)} label: {
          HStack(spacing: 8) {
            if store.operation == .starting {ProgressView().tint(VKZPalette.background)}
            Text(store.operation == .starting ? "Preparing…" : room.localRole == .host ? (isArena ? "Align arena" : "Start duel") : "Simulate host start")
          }
        }
        .buttonStyle(VKZPrimaryButtonStyle())
        .disabled(!canStart || store.isBusy || store.isMatchInputLocked)
        .opacity(canStart ? 1 : 0.45)
      }
    }
  }

  private var readinessGuidance: String {
    if store.isMatchInputLocked {return "Waiting for the lobby connection to recover."}
    if room.players.count < 2 {return "Invite at least one more player to begin."}
    if room.players.contains(where: {!$0.isConnected}) {return "Waiting for disconnected players to return."}
    let waiting = room.players.filter {!$0.isReady}
    if !waiting.isEmpty {
      return waiting.count == 1 && waiting[0].id == room.localPlayerID
        ? "Everyone else is ready. Ready up when you are."
        : "\(waiting.count) \(waiting.count == 1 ? "player still needs" : "players still need") to ready up."
    }
    if room.localRole == .host {
      return isArena ? "All players ready. Next, align your shared play area." : "Both players ready. Start when you are."
    }
    return isArena ? "You’re ready. Waiting for the host to begin alignment." : "You’re ready. Waiting for the host to start."
  }

  private func playerRow(_ player: LobbyPlayer) -> some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {playerIdentity(player); playerStatus(player)}
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 12) {playerIdentity(player); Spacer(minLength: 8); playerStatus(player)}
      }
    }
    .padding(14).background(VKZPalette.panel, in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(player.displayName), \(player.id == room.localPlayerID ? "you, " : "")\(player.role == .host ? "host, " : "")\(player.isConnected ? (player.isReady ? "ready" : "not ready") : "disconnected")")
  }

  private func playerIdentity(_ player: LobbyPlayer) -> some View {
    HStack(spacing: 10) {
      Image(systemName: player.role == .host ? "crown.fill" : "person.fill")
        .foregroundStyle(player.role == .host ? VKZPalette.acquisition : VKZPalette.telemetry).frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text(player.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
        Text(player.id == room.localPlayerID ? "YOU" : player.role == .host ? "HOST" : "PLAYER")
          .font(.caption2.monospaced()).foregroundStyle(VKZPalette.textMuted)
      }
    }
  }

  private func playerStatus(_ player: LobbyPlayer) -> some View {
    VKZStatusPill(label: player.isConnected ? (player.isReady ? "READY" : "NOT READY") : "DISCONNECTED",
      color: player.isConnected && player.isReady ? VKZPalette.ready : VKZPalette.textMuted)
  }

  #if canImport(UIKit)
  private var qrInvite: some View {
    DisclosureGroup(isExpanded: $showQRCode) {
      if let image = DuelQRCode.image(for: DuelInviteLink.url(for: room.code)) {
        VStack(spacing: 12) {
          Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            .frame(maxWidth: 180, maxHeight: 180).padding(8).background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("QR invitation for \(matchName.lowercased()) code, \(spokenCode)")
          Text("Scan this code on another player’s phone.").font(.subheadline).foregroundStyle(VKZPalette.textMuted)
        }
        .frame(maxWidth: .infinity).padding(.top, 12)
      }
    } label: {
      Label("Show QR invite", systemImage: "qrcode").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
    }
    .tint(VKZPalette.telemetry).padding(.horizontal, 4)
  }
  #endif

  #if DEBUG
  @ViewBuilder private var shellControls: some View {
    if !store.isLiveNetworking {
      VStack(alignment: .leading, spacing: 10) {
        Text("LOCAL SHELL CONTROLS").font(.caption2.weight(.semibold).monospaced()).foregroundStyle(VKZPalette.textMuted)
        if !room.isFull, room.localRole == .host {
          Button("Simulate Opponent Joining") {store.simulateOpponentJoined()}.buttonStyle(VKZSecondaryButtonStyle())
        } else if let opponent {
          Button(opponent.isReady ? "Simulate Opponent Not Ready" : "Simulate Opponent Ready") {
            store.toggleReady(for: opponent.id, currentValue: opponent.isReady)
          }.buttonStyle(VKZSecondaryButtonStyle())
        }
      }
    }
  }
  #endif
}
