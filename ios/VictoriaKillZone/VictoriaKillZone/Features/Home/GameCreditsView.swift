import SwiftUI

struct GameCreditsView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Anatomical model")
          .font(.title2.bold())
        Text("BodyParts3D, © The Database Center for Life Science licensed under CC Attribution 4.0 International")
          .font(.body)
        Text("Meshes adapted through simplification, part grouping, retargeting, and game materials.")
          .foregroundStyle(VKZPalette.textMuted)
        Link("BodyParts3D source and attribution",
          destination: URL(string: "https://dbarchive.biosciencedbc.jp/en/bodyparts3d/lic.html")!)
        Link("Creative Commons Attribution 4.0 International",
          destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
      }
      .tint(VKZPalette.telemetry)
      .padding(24)
      .frame(maxWidth: 600, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .foregroundStyle(VKZPalette.text)
    .background(VKZPalette.background)
    .navigationTitle("Credits")
  }
}
