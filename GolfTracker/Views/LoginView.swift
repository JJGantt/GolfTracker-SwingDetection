import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @ObservedObject private var auth = AuthManager.shared
    @State private var errorMessage: String?

    var onSignedIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to GolfTracker")
                    .font(.largeTitle.bold())
                Text("Your rounds follow you across devices and reinstalls.")
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)

            Spacer()

            if auth.isSigningIn {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                SignInWithAppleButton(.signIn,
                    onRequest: { request in
                        request.requestedScopes = [.fullName, .email]
                    },
                    onCompletion: { _ in
                        // Actual flow runs through AuthManager below
                    }
                )
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 50)
                .cornerRadius(12)
                .overlay(
                    // Make the whole button clickable and route through AuthManager
                    // for consistent session handling.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { triggerSignIn() }
                )
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
    }

    private func triggerSignIn() {
        errorMessage = nil
        auth.signInWithApple { result in
            switch result {
            case .success:
                onSignedIn()
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }
}
