// LoginView.swift — Entry screen with Sign in with Apple + name entry
import SwiftUI
import AuthenticationServices
import Combine

struct LoginView: View {
    @Environment(AppSession.self) var session
    @State private var name      = ""
    @State private var animateIn = false
    @State private var appleError: String? = nil

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

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

                // Guest path — requires a name. This and Sign in with Apple are the ONLY two
                // ways past this screen; the old "Continue without a name" bypass is removed.
                Button {
                    session.enterKitchen(name: name)
                } label: {
                    Text("Continue as Guest")
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .foregroundStyle(session.themeTextColor.opacity(trimmedName.isEmpty ? 0.45 : 1))
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .background(Color.stockedGold.opacity(trimmedName.isEmpty ? 0.45 : 1))
                        .clipShape(Capsule())
                }
                .disabled(trimmedName.isEmpty)
                .padding(.horizontal, 32)
                .opacity(animateIn ? 1 : 0)
                .padding(.bottom, 10)

                Text("Sign in with Apple, or continue as a guest with your name.")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
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
        .alert("Keep your existing data?", isPresented: migrationBinding) {
            Button("Keep It") { session.resolveSignInMigration(keepGuestData: true) }
            Button("Start Fresh", role: .destructive) {
                session.resolveSignInMigration(keepGuestData: false)
            }
        } message: {
            Text("You had items saved before signing in. Keep them in your account, or start fresh with a clean kitchen?")
        }

    }

    // Two-way binding so the alert can dismiss itself; writing false clears the pending flag
    // without taking a migration action (used only if the alert is dismissed by other means).
    private var migrationBinding: Binding<Bool> {
        Binding(
            get: { session.pendingSignInMigration },
            set: { if !$0 { session.pendingSignInMigration = false } }
        )
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            let userID    = cred.user
            // Apple only includes fullName/email on the FIRST authorization for a given Apple
            // ID; on every later sign-in they're nil. Capture everything Apple sends into the
            // per-Apple-ID vault, then read the merged profile back. Because the vault is keyed
            // to the Apple ID, sign-out can wipe the active profile completely while a returning
            // user still gets their real name and email restored here.
            let freshFirst = cred.fullName?.givenName?.trimmingCharacters(in: .whitespaces) ?? ""
            let freshFull: String = {
                guard let n = cred.fullName else { return "" }
                return [n.givenName, n.familyName]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }()
            let freshEmail = cred.email?.trimmingCharacters(in: .whitespaces) ?? ""
            AppleProfileVault.remember(userID: userID, firstName: freshFirst,
                                       fullName: freshFull, email: freshEmail)
            let stored = AppleProfileVault.profile(for: userID)

            let firstName = freshFirst.isEmpty ? (stored?.firstName ?? "") : freshFirst
            // Keep the legacy single-name cache in step for anything still reading it.
            if !firstName.isEmpty {
                UserDefaults.standard.set(firstName, forKey: DBKey.appleFirstName.rawValue)
            }

            // Greeting shows the FIRST name only (e.g. "Good Morning, Alex"). Fall back to the
            // remembered email prefix, then Chef, only when we have never captured a first name.
            let emailForFallback = freshEmail.isEmpty ? (stored?.email ?? "") : freshEmail
            let displayName = firstName.isEmpty
                ? (emailForFallback.components(separatedBy: "@").first ?? "Chef")
                : firstName

            // Detect whether the user already has local guest data BEFORE we register the
            // account, so signIn() can flag the migrate-vs-discard prompt.
            let hadGuestData = !session.guestStore.inventoryItems.isEmpty
                            || !session.guestStore.groceryItems.isEmpty
                            || !session.guestStore.userRecipes.isEmpty

            // Register the account (accountType -> .registered, sync enabled, wasGuest cleared).
            // The old code called enterKitchen(), which forced accountType back to .guest.
            session.signIn(appleUserID: userID, name: displayName, hadGuestData: hadGuestData)

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
