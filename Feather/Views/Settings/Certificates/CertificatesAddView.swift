//
//  CertificatesAddView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers

// MARK: - View
struct CertificatesAddView: View {
	@Environment(\.dismiss) private var dismiss
	
	@State private var _p12URL: URL? = nil
	@State private var _provisionURL: URL? = nil
	@State private var _p12Password: String = ""
	@State private var _certificateName: String = ""
    @State private var _isValidating = false
    @State private var _validationMessage: String?
    @State private var _importError: String?
    @State private var _filesValidated = false
    @State private var _validationGeneration = 0

    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var _existingCertificates: FetchedResults<CertificatePair>

	
	@State private var _isImportingP12Presenting = false
	@State private var _isImportingMobileProvisionPresenting = false
	
	var saveButtonDisabled: Bool {
		!_filesValidated || _isValidating
	}
	
    // MARK: Body
    var body: some View {
        NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
            Form {
                Section {
                    _importButton("Import Certificate File", file: _p12URL) {
                        _isImportingP12Presenting = true
                    }
                    if let file = _p12URL {
                        LabeledContent("P12", value: file.lastPathComponent)
                            .font(.subheadline)
                    }
                    _importButton("Import Provisioning File", file: _provisionURL) {
                        _isImportingMobileProvisionPresenting = true
                    }
                    if let file = _provisionURL {
                        LabeledContent("Provisioning", value: file.lastPathComponent)
                            .font(.subheadline)
                    }
                } header: {
                    Text("Files")
                } footer: {
                    Text("Both files must belong to the same signing identity.")
                }

                Section {
                    SecureField(.localized("Enter Password"), text: $_p12Password)
                } header: {
                    Text("Password")
                } footer: {
                    Text("Enter the P12 password. Leave blank only if the archive has no password.")
                }

                Section {
                    TextField(.localized("Nickname (Optional)"), text: $_certificateName)
                } header: {
                    Text("Identity")
                }

                if _isValidating || _validationMessage != nil {
                    Section {
                        if _isValidating {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Validating signing files…")
                            }
                        }
                        if let _validationMessage {
                            Label(_validationMessage, systemImage: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Import Validation")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        _saveCertificate()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(_filesValidated ? Color.accentColor : Color.secondary)
                    }
                    .disabled(saveButtonDisabled)
                    .accessibilityLabel("Import Certificate")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close New Certificate")
                }
            }
            .onChange(of: _p12URL) { _ in _scheduleValidation() }
            .onChange(of: _provisionURL) { _ in _scheduleValidation() }
            .onChange(of: _p12Password) { _ in _scheduleValidation() }
            .alert("Certificate Import", isPresented: Binding(
                get: { _importError != nil },
                set: { if !$0 { _importError = nil } }
            )) {
                Button("OK", role: .cancel) { _importError = nil }
            } message: {
                Text(_importError ?? "")
            }
            .sheet(isPresented: $_isImportingP12Presenting) {
                FileImporterRepresentableView(
                    allowedContentTypes: [.p12],
                    onDocumentsPicked: { urls in
                        guard let selectedFileURL = urls.first else { return }
                        _p12URL = selectedFileURL
                        _scheduleValidation()
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $_isImportingMobileProvisionPresenting) {
                FileImporterRepresentableView(
                    allowedContentTypes: [.mobileProvision],
                    onDocumentsPicked: { urls in
                        guard let selectedFileURL = urls.first else { return }
                        _provisionURL = selectedFileURL
                        _validationMessage = nil
                    }
                )
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Extension: View
extension CertificatesAddView {
	@ViewBuilder
	private func _importButton(
		_ title: String,
		file: URL?,
		action: @escaping () -> Void
	) -> some View {
		Button(title) {
			action()
		}
		.foregroundColor(file == nil ? .accentColor : .disabled())
		.disabled(file != nil)
		.animation(.easeInOut(duration: 0.3), value: file != nil)
	}
}

// MARK: - Import validation
extension CertificatesAddView {
    private func _scheduleValidation() {
        _validationGeneration += 1
        let generation = _validationGeneration
        _filesValidated = false
        _validationMessage = nil
        _importError = nil
        _isValidating = false

        guard let p12 = _p12URL, let provision = _provisionURL else { return }

        let password = _p12Password
        let existingUUIDs = Set(_existingCertificates.compactMap {
            Storage.shared.getProvisionFileDecoded(for: $0)?.UUID.lowercased()
        })

        _isValidating = true
        Task {
            // Allow password edits to settle before expensive PKCS#12 decoding.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard generation == _validationGeneration else { return }

            let result = await Task.detached(priority: .userInitiated) {
                ZagCertificateImportValidation.validate(
                    p12: p12, provision: provision,
                    password: password, existingUUIDs: existingUUIDs
                )
            }.value

            guard generation == _validationGeneration else { return }
            _isValidating = false
            _filesValidated = result.isValid
            _validationMessage = result.isValid
                ? "Signing identity and provisioning profile match."
                : nil
            // Don't interrupt typing with alerts. A failed validation remains
            // disabled; tapping Save only becomes possible after a valid match.
        }
    }

    private func _saveCertificate() {
        guard _filesValidated, !_isValidating,
              let p12URL = _p12URL,
              let provisionURL = _provisionURL else { return }

        _isValidating = true
        _filesValidated = false
        _validationMessage = "Saving signing identity…"
        _importError = nil

        let password = _p12Password
        let name = _certificateName
        FR.handleCertificateFiles(
                p12URL: p12URL,
                provisionURL: provisionURL,
                p12Password: password,
                certificateName: name
        ) { error in
            _isValidating = false
            if let error {
                _validationMessage = nil
                _importError = "Could not save the certificate: \(error.localizedDescription)"
                _scheduleValidation()
            } else {
                dismiss()
            }
        }
    }
}
