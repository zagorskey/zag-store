import SwiftUI
import NimbleViews

// MARK: - Zag Store About
struct AboutView: View {
    @State private var gradientRotation: Double = 0
    // Only show a recorded successful update, never filesystem creation dates
    // (which may incorrectly resolve to the Unix epoch).
    @AppStorage("ZagStore.lastSuccessfulUpdateTimestamp") private var lastSuccessfulUpdateTimestamp: Double = 0

    private var lastUpdatedText: String {
        guard lastSuccessfulUpdateTimestamp > 0 else { return "Never" }
        let date = Date(timeIntervalSince1970: lastSuccessfulUpdateTimestamp)
        guard date > Date(timeIntervalSince1970: 946684800), date <= Date() else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NBList(.localized("About")) {
            Section {
                VStack(spacing: 12) {
                    FRAppIconView(size: 72)

                    Text("Zag Store")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)

                    (
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")")
                            .foregroundColor(.white)
                        + Text(" · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")")
                            .foregroundColor(.secondary)
                    )
                    .font(.subheadline)

                    Text("Last updated: \(lastUpdatedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(EmptyView())

            Section {
                Button {
                    UIApplication.open("https://github.com/zagorskey")
                } label: {
                    HStack(spacing: 14) {
                    Image("ZagAuthorPortrait")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                        .padding(3)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    AngularGradient(colors: [.blue, .purple, .pink, .orange, .blue], center: .center, angle: .degrees(gradientRotation)),
                                    lineWidth: 1.5
                                )
                                .animation(.linear(duration: 5).repeatForever(autoreverses: false), value: gradientRotation)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("ZAGORSKI")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("Author")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary.opacity(0.65))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .onAppear {
                    gradientRotation = 360
                }
            } header: {
                Text("Credits")
            }
        }
    }
}
