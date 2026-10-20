//
//  ZagCertificateHealthView.swift
//  Zag Store
//
//  Local signing file health and opt-in expiry reminders.
//

import SwiftUI
import UserNotifications

@MainActor
enum ZagCertificateExpiryNotifications {
    static let enabledKey = "ZagStore.certificateExpiryNotificationsEnabled"
    private static let prefix = "zagstore.certificate.expiry."

    static func updatePermissionAndSchedule(enabled: Bool) async -> String? {
        let center = UNUserNotificationCenter.current()
        if !enabled {
            await _removeScheduled()
            return nil
        }

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                let accepted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                if !accepted {
                    UserDefaults.standard.set(false, forKey: enabledKey)
                    return "Notifications were not authorised. You can enable them in iOS Settings."
                }
            } catch {
                UserDefaults.standard.set(false, forKey: enabledKey)
                return "Notification permission could not be requested."
            }
        } else if settings.authorizationStatus == .denied {
            UserDefaults.standard.set(false, forKey: enabledKey)
            return "Notifications are disabled for Zag Store in iOS Settings."
        }

        await refresh()
        return nil
    }

    static func refresh() async {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        await _removeScheduled()

        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let now = Date()

        for cert in Storage.shared.getAllCertificates() {
            guard let profile = Storage.shared.getProvisionFileDecoded(for: cert),
                  profile.ExpirationDate > now,
                  let id = cert.uuid else { continue }

            let name = cert.nickname ?? profile.Name
            for days in [30, 7, 1] {
                guard let day = calendar.date(byAdding: .day, value: -days,
                                             to: profile.ExpirationDate),
                      let date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                      date > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Signing Certificate Expiring"
                content.body = "\(name) expires in \(days) day\(days == 1 ? "" : "s")."
                content.sound = .default

                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: date
                )
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: components, repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: "\(prefix)\(id).\(days)",
                    content: content, trigger: trigger
                )
                try? await center.add(request)
            }
        }
    }

    private static func _removeScheduled() async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let ours = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ours.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }
}

struct ZagCertificateHealthView: View {
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var certificates: FetchedResults<CertificatePair>

    @AppStorage(ZagCertificateExpiryNotifications.enabledKey)
    private var remindersEnabled = false

    @State private var permissionMessage: String?

    private struct HealthItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let needsAttention: Bool
    }

    var body: some View {
        Form {
            Section {
                Toggle("Expiry Notifications", isOn: $remindersEnabled)
                    .onChange(of: remindersEnabled) { enabled in
                        Task {
                            permissionMessage = await ZagCertificateExpiryNotifications
                                .updatePermissionAndSchedule(enabled: enabled)
                        }
                    }

                if let permissionMessage {
                    Label(permissionMessage, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Expiry Reminders")
            } footer: {
                Text("Optional local reminders at 30, 7 and 1 days before profile expiry, at approximately 9 AM. iOS controls notification delivery. No certificate or password is uploaded.")
            }

            Section {
                if certificates.isEmpty {
                    Label("No signing identities imported", systemImage: "tray")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(certificates, id: \.objectID) { cert in
                        _healthRow(cert)
                    }
                }
            } header: {
                Text("Signing Identity Health")
            } footer: {
                Text("Checks use local files, dates and previously recorded status. A passing result does not verify Apple revocation or successful app installation.")
            }
        }
        .navigationTitle("Certificate Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if remindersEnabled {
                await ZagCertificateExpiryNotifications.refresh()
            }
        }
    }

    @ViewBuilder
    private func _healthRow(_ cert: CertificatePair) -> some View {
        let items = _checks(for: cert)
        let problems = items.filter(\.needsAttention).count

        DisclosureGroup {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.needsAttention
                          ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(item.needsAttention ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: problems == 0 ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(problems == 0 ? Color.accentColor : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cert.nickname
                         ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name
                         ?? "Signing Identity")
                        .font(.subheadline.weight(.medium))
                    Text(problems == 0 ? "Local checks passed" : "\(problems) item(s) need attention")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func _checks(for cert: CertificatePair) -> [HealthItem] {
        let profile = Storage.shared.getProvisionFileDecoded(for: cert)
        let p12 = Storage.shared.getFile(.certificate, from: cert)
        let now = Date()

        var result: [HealthItem] = [
            HealthItem(id: "p12", title: "P12 File",
                       detail: p12 == nil ? "Missing" : "File found (identity not reverified)",
                       needsAttention: p12 == nil),
            HealthItem(id: "profile", title: "Provisioning Profile",
                       detail: profile == nil ? "Missing or unreadable" : "Readable",
                       needsAttention: profile == nil)
        ]

        if let profile {
            let current = profile.CreationDate <= now && profile.ExpirationDate > now
            result.append(HealthItem(
                id: "dates", title: "Profile Validity",
                detail: current
                    ? "Expires \(profile.ExpirationDate.formatted(date: .abbreviated, time: .omitted))"
                    : "Not current — check profile dates",
                needsAttention: !current
            ))

            let days = Calendar.current.dateComponents(
                [.day], from: now, to: profile.ExpirationDate
            ).day ?? 0
            result.append(HealthItem(
                id: "expiry", title: "Upcoming Expiry",
                detail: days < 0 ? "Expired" : "\(max(days, 0)) days remaining",
                needsAttention: days <= 30
            ))

            let duplicateCount = certificates.filter {
                $0.objectID != cert.objectID
                    && Storage.shared.getProvisionFileDecoded(for: $0)?.UUID == profile.UUID
            }.count
            result.append(HealthItem(
                id: "duplicates", title: "Duplicate Profile UUID",
                detail: duplicateCount == 0
                    ? "No duplicate profile found"
                    : "\(duplicateCount) other imported identity/identities use this UUID",
                needsAttention: duplicateCount > 0
            ))
        }

        result.append(HealthItem(
            id: "revocation", title: "Revocation Record",
            detail: cert.revoked
                ? "Previously marked revoked"
                : "Not confirmed by Apple",
            needsAttention: cert.revoked
        ))
        return result
    }
}
