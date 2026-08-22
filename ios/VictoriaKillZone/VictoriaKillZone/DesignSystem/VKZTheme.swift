import SwiftUI

enum VKZPalette {
  static let background = Color.black
  static let panel = Color.white.opacity(0.08)
  static let border = Color.white.opacity(0.16)
  static let telemetry = Color.cyan
  static let acquisition = Color.orange
  static let danger = Color.red
  static let ready = Color.green
}

struct VKZPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 15)
      .foregroundStyle(.black)
      .background(configuration.isPressed ? Color.white.opacity(0.72) : Color.white)
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
      .foregroundStyle(.white)
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
