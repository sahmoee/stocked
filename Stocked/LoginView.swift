// LoginView.swift — Entry screen with Sign in with Apple + name entry
import SwiftUI
import AuthenticationServices
import Combine

struct LoginView: View {
    @Environment(AppSession.self) var session
    @State private var name      = ""
    @State private var animateIn = false
    @State private var appleError: String? = nil

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            // Constrain content width on iPad — login form looks better centred and narrower
            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 10) {
                    StockedWordmark(size: 52)
                    Text("Kitchen Peace of Mind")
                        .font(.system(size: 14, weight: .light, design: .serif))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                        .tracking(1.4)
                }
                .opacity(animateIn ? 1 : 0).offset(y: animateIn ? 0 : 16)
                .padding(.bottom, 52)

                // Sign in with Apple — overlay approach avoids NSAutoresizingMaskLayoutConstraint conflict
                Color.clear
                    .frame(maxWidth: 375)   // Apple's internal cap — match it to prevent NSLayoutConstraint conflict on iPad
                    .frame(height: 54)
                    .overlay {
                        SignInWithAppleButton(.signIn,
                            onRequest: { request in
                                request.requestedScopes = [.fullName, .email]
                            },
                            onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .allowsHitTesting(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 27))
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)   // centre on iPad
                    .opacity(animateIn ? 1 : 0)
                    .padding(.bottom, 16)

                // Divider
                HStack {
                    Rectangle().fill(Color.stockedCharcoal.opacity(0.18)).frame(height: 1)
                    Text("or").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.35)).padding(.horizontal, 12)
                    Rectangle().fill(Color.stockedCharcoal.opacity(0.18)).frame(height: 1)
                }
                .padding(.horizontal, 32).padding(.bottom, 16)
                .opacity(animateIn ? 1 : 0)

                // Name field
                VStack(spacing: 6) {
                    HStack {
                        Text("Name")
                            .font(.system(size: 16))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 60, alignment: .leading)
                        TextField("What should we call you?", text: $name)
                    .foregroundStyle(session.themeTextColor)
                            .font(.system(size: 16))
                            .foregroundStyle(session.themeTextColor)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 32)
                    Rectangle().fill(Color.stockedCharcoal.opacity(0.18)).frame(height: 1).padding(.horizontal, 32)
                }
                .opacity(animateIn ? 1 : 0)
                .padding(.bottom, 28)

                // Enter Kitchen
                Button { session.enterKitchen(name: name) } label: {
                    Text("Enter Kitchen")
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .background(Color.stockedGold).clipShape(Capsule())
                }
                .padding(.horizontal, 32)
                .opacity(animateIn ? 1 : 0)
                .padding(.bottom, 14)

                // Skip name
                Button { session.enterKitchen() } label: {
                    Text("Continue without a name")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .opacity(animateIn ? 1 : 0)

                if let err = appleError {
                    Text(err).font(.system(size: 12)).foregroundStyle(.red)
                        .padding(.top, 8).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .frame(maxWidth: 480)   // centre and constrain on iPad
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) { animateIn = true }
        }

    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            let userID    = cred.user
            let firstName = cred.fullName?.givenName ?? ""
            // Greeting shows the FIRST name only (e.g. "Good Morning, Alex"), so store
            // the given name as the display name; fall back to the email prefix, then Chef.
            let displayName = firstName.isEmpty
                ? (cred.email?.components(separatedBy: "@").first ?? "Chef")
                : firstName

            session.appleUserID = userID
            session.enterKitchen(name: displayName)

            // Returning user: pull their latest iCloud backup so inventory + preferences
            // come back automatically. Merge-style so it never wipes anything local.
            // Uses the session-retained manager so the async CloudKit task isn't orphaned.
            session.transferManager.restoreFromiCloud(into: session.guestStore, merge: true)

        case .failure(let error):
            let nsErr = error as NSError
            // Code 1001 = user cancelled — don't show error for that
            if nsErr.code != 1001 {
                appleError = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }
}

#Preview { LoginView().environment(AppSession()) }
