import SwiftUI
import NimbleViews

// MARK: - Zag Store About
struct AboutView: View {
    var body: some View {
        NBList(.localized("About")) {
            Section {
                VStack(spacing: 12) {
                    FRAppIconView(size: 72)

                    Text("Zag Store")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)

                    Text("Version \(Bundle.main.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(EmptyView())

            Section {
                HStack(spacing: 14) {
                    Image("ZagAuthorPortrait")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text("ZAGORSKI")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Author")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Author")
            }
        }
    }
}
