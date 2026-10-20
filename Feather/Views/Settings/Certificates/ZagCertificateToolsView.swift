//
//  ZagCertificateToolsView.swift
//  Zag Store
//
//  A compact navigation hub for existing certificate utilities.
//

import SwiftUI

struct ZagCertificateToolsView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ZagCertificateHealthView()
                } label: {
                    Label("Certificate Health & Reminders", systemImage: "heart.text.square")
                }
            } header: {
                Text("Health")
            } footer: {
                Text("Review local signing-file status and manage optional expiry notifications.")
            }

            Section {
                NavigationLink {
                    ZagProvisioningProfileInspectorView()
                } label: {
                    Label("Inspect Provisioning Profile", systemImage: "doc.text.magnifyingglass")
                }

                NavigationLink {
                    ZagStoredProfileComparisonView()
                } label: {
                    Label("Compare Stored Profiles", systemImage: "arrow.left.arrow.right")
                }
            } header: {
                Text("Provisioning Profiles")
            } footer: {
                Text("Inspect or compare profiles without changing the stored signing identities.")
            }
        }
        .navigationTitle("Certificate Health & Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
