import SwiftUI
import NimbleViews

// MARK: - Zag Store About
struct AboutView: View {
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

                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")")
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    Text("Last updated: \(lastUpdatedText)")
                        .font(.caption)
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
                Text("Credits")
            }
        }
    }
}
