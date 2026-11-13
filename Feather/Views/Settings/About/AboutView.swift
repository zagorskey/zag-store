import SwiftUI
import NimbleViews

// MARK: - Zag Store About
struct AboutView: View {
    @State private var gradientRotation: Double = 0
    // Only show a recorded successful update, never filesystem creation dates
    // (which may incorrectly resolve to the Unix epoch).
    @AppStorage("ZagStore.lastSuccessfulUpdateTimestamp") private var lastSuccessfulUpdateTimestamp: Double = 0
    @AppStorage("Feather.userTintColor") private var userTintColor = "#0090FF"

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

            Section {
                Button {
                    UIApplication.open("https://github.com/claration/Feather")
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(ZagWideGamutTint.color(hex: userTintColor))
                            .frame(width: 52, height: 52)
                            .zagAboutGlass(in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Feather")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.primary)
                            Text("The open-source app Zag Store is built on")
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

                ForEach(Self.featherCredits, id: \.github) { credit in
                    Button {
                        UIApplication.open("https://github.com/\(credit.github)")
                    } label: {
                        HStack {
                            FRIconCellView(
                                title: credit.name,
                                subtitle: credit.role,
                                iconUrl: URL(string: "https://github.com/\(credit.github).png"),
                                size: 40,
                                isCircle: true
                            )
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary.opacity(0.65))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Built on Feather")
            } footer: {
                Text("Zag Store is a fork of Feather by Samara (claration) and its contributors. Like Feather, it is free software under the GNU General Public License v3.0, and comes with no warranty.")
            }

            Section {
                _linkRow("GNU General Public License v3.0", systemImage: "doc.text", url: "https://www.gnu.org/licenses/gpl-3.0.html")
                _linkRow("Source Code", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/zagorskey/zag-store")
                _linkRow("Acknowledgements", systemImage: "list.bullet.rectangle", url: UIApplication.openSettingsURLString)
            } header: {
                Text("Licence")
            } footer: {
                Text("Acknowledgements opens Zag Store in the Settings app, which lists the licences of every open-source component.")
            }
        }
    }

    // Feather's own credits, as Feather 2.9.0 lists them on its About screen.
    private struct FeatherCredit {
        let name: String
        let role: String
        let github: String
    }

    private static let featherCredits = [
        FeatherCredit(name: "C", role: "Developer", github: "claration"),
        FeatherCredit(name: "Asami", role: "Developer", github: "Nyasami"),
        FeatherCredit(name: "Lakhan Lothiyi", role: "AltStore Repositories", github: "llsc12"),
    ]

    private func _linkRow(_ title: String, systemImage: String, url: String) -> some View {
        Button {
            UIApplication.open(url)
        } label: {
            HStack {
                Label {
                    Text(title)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(ZagWideGamutTint.color(hex: userTintColor))
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func zagAboutGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
