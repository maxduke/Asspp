//
//  AddAccountView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import SwiftUI

struct AddAccountView: View {
    @State private var vm = AppStore.this
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isPasswordHidden = true

    @State private var codeRequired: Bool = false
    @State private var code: String = ""

    @State private var error: Error?
    @State private var authenticationTask: Task<Void, Never>?
    @State private var progress: AuthenticationProgress = .contactingApple

    private var progressMessage: LocalizedStringKey {
        switch progress {
        case .preparingComponents:
            "Preparing sign-in components. The first download may take a few minutes."
        case .preparingSignature:
            "Preparing secure sign-in…"
        case .contactingApple:
            "Signing in to Apple…"
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Email (Apple ID)", text: $email)
                #if os(iOS)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                #endif
                if isPasswordHidden {
                    SecureField("Password", text: $password)
                    #if os(iOS)
                        .textContentType(.password)
                    #endif
                } else {
                    TextField(text: $password) {
                        Text("Password")
                            .font(.body)
                    }
                    #if os(iOS)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textContentType(.password)
                    #endif
                    .font(.body.monospaced())
                }
            } header: {
                HStack {
                    Text("Apple ID")
                    Spacer()
                    Button(isPasswordHidden ? "Show Password" : "Hide Password") {
                        isPasswordHidden.toggle()
                    }
                    .disabled(password.isEmpty)
                }
            } footer: {
                Text("Your account is saved in your Keychain and will be synced across devices with the same iCloud account signed in.")
            }
            .disabled(authenticationTask != nil)
            if codeRequired {
                Section {
                    TextField("2FA Code (Optional)", text: $code)
                    #if os(iOS)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .keyboardType(.numberPad)
                    #endif
                } header: {
                    Text("2FA Code")
                } footer: {
                    Text("Although the 2FA code is marked as optional, it's because we don't know if you have it enabled or just entered an incorrect password. Provide it if you have 2FA enabled.\n\nhttps://support.apple.com/102606")
                }
                .transition(.opacity)
                .disabled(authenticationTask != nil)
            }
            Section {
                if authenticationTask != nil {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(progressMessage)
                    }
                    Button("Cancel", role: .cancel) {
                        authenticationTask?.cancel()
                    }
                } else {
                    Button("Authenticate") {
                        error = nil
                        progress = .contactingApple
                        authenticationTask = Task { @MainActor in
                            defer { authenticationTask = nil }
                            do {
                                _ = try await vm.authenticate(email: email, password: password, code: code) { value in
                                    Task { @MainActor in progress = value }
                                }
                                dismiss()
                            } catch is CancellationError {
                                // Closing or cancelling sign-in does not request 2FA.
                            } catch {
                                self.error = error
                                codeRequired = true
                            }
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty)
                }
            } footer: {
                if let error {
                    Text(error.localizedDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .transition(.opacity)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { authenticationTask?.cancel() }
        .animation(.spring, value: codeRequired)
        #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .navigationTitle("Add Account")
    }
}
