import SwiftUI

enum VKZPalette {
  // Frozen G1/G2 tokens from design/slices/001-g1-g2-network-vertical-slice.md.
  static let background = Color(red: 7 / 255, green: 11 / 255, blue: 16 / 255)
  static let panel = Color(red: 17 / 255, green: 25 / 255, blue: 35 / 255)
  static let surfaceRaised = Color(red: 25 / 255, green: 37 / 255, blue: 51 / 255)
  static let text = Color(red: 245 / 255, green: 248 / 255, blue: 252 / 255)
  static let textMuted = Color(red: 168 / 255, green: 180 / 255, blue: 194 / 255)
  static let telemetry = Color(red: 53 / 255, green: 217 / 255, blue: 230 / 255)
  static let ready = Color(red: 67 / 255, green: 209 / 255, blue: 125 / 255)
  static let pending = Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255)
  static let acquisition = pending
  static let danger = Color(red: 255 / 255, green: 83 / 255, blue: 100 / 255)
  static let focus = Color.white
  static let border = textMuted.opacity(0.22)
}

struct VKZPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 15)
      .foregroundStyle(VKZPalette.background)
      .background(configuration.isPressed ? VKZPalette.text.opacity(0.72) : VKZPalette.text)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct VKZSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .foregroundStyle(VKZPalette.text)
      .background(VKZPalette.panel)
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(VKZPalette.border)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .opacity(configuration.isPressed ? 0.72 : 1)
  }
}

struct VKZStatusPill: View {
  let label: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(label)
        .font(.caption.weight(.semibold).monospaced())
    }
    .foregroundStyle(color)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(color.opacity(0.12))
    .clipShape(Capsule())
  }
}

struct VKZPanel<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(16)
      .background(VKZPalette.panel)
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(VKZPalette.border)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

extension View {
  @ViewBuilder
  func vkzCallsignInputTraits() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.words)
        .autocorrectionDisabled()
    #else
      self
    #endif
  }

  @ViewBuilder
  func vkzJoinCodeInputTraits() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .textContentType(.oneTimeCode)
    #else
      self
    #endif
  }
}
