//
//  ZagCertificateExportView.swift
//  Zag Store
//
//  Explicit, read-only file sharing. Passwords are never exported.
//

import SwiftUI
import UIKit

struct ZagCertificateExportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cert: CertificatePair

    @State private var includePrivateKey = false
    @State private var confirming = false
    @State private var sharing: SharePayload?
    @State private var errorMessage: String?

    private struct SharePayload: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        Form {
            Section {
                if let profile = Storage.shared.getProvisionFileDecoded(for: cert) {
                    LabeledContent("Identity", value: cert.nickname ?? profile.Name)
                    LabeledContent("Team", value: profile.TeamName)
                }
                Toggle("Include P12 Private Key", isOn: $includePrivateKey)
                    .tint(.accentColor)
            } header: {
                Text("Export Options")
            } footer: {
                Text(includePrivateKey
                     ? "A P12 contains a private signing key. Only share it with a destination you trust. Zag Store will not include the P12 password."
                     : "Exports only the provisioning profile. This does not contain your P12 private signing key.")
            }

            Section {
                Button {
                    _prepareExport()
                } label: {
                    Label("Share Selected Files", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Share")
            } footer: {
                Text("The original signing files stay in Zag Store. The receiving app controls any copies you share.")
            }
        }
        .navigationTitle("Export Signing Files")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            includePrivateKey ? "Share Private Signing Key?" : "Share Provisioning Profile?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(includePrivateKey ? "Share P12 and Profile" : "Share Profile") {
                _presentShare()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(includePrivateKey
                 ? "Anyone who obtains the P12 and its password may be able to sign apps as this identity. The password will not be included."
                 : "This shares a copy of your provisioning profile, not your private signing key.")
        }
        .sheet(item: $sharing) { payload in
            ZagCertificateShareSheet(urls: payload.urls)
                .ignoresSafeArea()
        }
        .alert("Export Unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func _prepareExport() {
        guard Storage.shared.getFile(.provision, from: cert) != nil else {
            errorMessage = "The provisioning profile is unavailable."
            return
        }
        if includePrivateKey && Storage.shared.getFile(.certificate, from: cert) == nil {
            errorMessage = "The P12 file is unavailable."
            return
        }
        confirming = true
    }

    private func _presentShare() {
        guard let profile = Storage.shared.getFile(.provision, from: cert) else {
            errorMessage = "The provisioning profile is unavailable."
            return
        }
        var urls = [profile]
        if includePrivateKey {
            guard let p12 = Storage.shared.getFile(.certificate, from: cert) else {
                errorMessage = "The P12 file is unavailable."
                return
            }
            urls.append(p12)
        }
        sharing = SharePayload(urls: urls)
    }
}

private struct ZagCertificateShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
