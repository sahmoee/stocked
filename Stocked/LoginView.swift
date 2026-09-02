// LoginView.swift — Entry screen with Sign in with Apple + name entry
import SwiftUI
import AuthenticationServices
import Combine

struct LoginView: View {
    @Environment(AppSession.self) var session
    @Environment(\.openURL) private var openURL
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
                        .scaledFont(14, weight: .light, design: .serif)
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
                    Text("or").scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.35)).padding(.horizontal, 12)
                    Rectangle().fill(Color.stockedCharcoal.opacity(0.18)).frame(height: 1)
                }
                .padding(.horizontal, 32).padding(.bottom, 16)
                .opacity(animateIn ? 1 : 0)

                // Name field
                VStack(spacing: 6) {
                    HStack {
                        Text("Name")
                            .scaledFont(16)
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 60, alignment: .leading)
                        TextField("What should we call you?", text: $name)
                    .foregroundStyle(session.themeTextColor)
                            .scaledFont(16)
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
                        .scaledFont(20, weight: .regular, design: .serif)
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
                    .scaledFont(12)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .opacity(animateIn ? 1 : 0)

                if let err = appleError {
                    Text(err).scaledFont(12).foregroundStyle(.red)
                        .padding(.top, 8).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Legal links — shown at account creation (App Store guideline 5.1.1).
                HStack(spacing: 6) {
                    Button("Privacy Policy") { if let u = URL(string: BuildConfig.privacyURL) { openURL(u) } }
                    Text("·").foregroundStyle(session.themeTextColor.opacity(0.3))
                    Button("Terms") { if let u = URL(string: BuildConfig.termsURL) { openURL(u) } }
                }
                .scaledFont(11)
                .tint(session.themeTextColor.opacity(0.5))
                .padding(.top, 10)
                .opacity(animateIn ? 1 : 0)

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
            // Upgrade the Worker session from guest → Apple-verified using this sign-in's
            // identity token (best-effort; the app keeps working if the Worker is unreachable).
            let appleJWT = cred.identityToken.flatMap { String(data: $0, encoding: .utf8) }
            Task { await StockedSession.shared.setAppleIdentityToken(appleJWT) }
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

            // FR-03 FIX: don't silently fall back to "Chef" (or a random private-relay email
            // prefix) when Apple gives no name. Register with whatever real first name we have
            // (from this auth or the Keychain vault); if that's empty, flag the name-entry prompt
            // so RootView asks the user directly. A non-relay email prefix is still an acceptable
            // greeting, so only prompt when we have neither a name nor a real email.
            let realEmail = (freshEmail.isEmpty ? (stored?.email ?? "") : freshEmail)
            let isPrivateRelay = realEmail.hasSuffix("@privaterelay.appleid.com")
            let emailPrefix = (realEmail.isEmpty || isPrivateRelay) ? "" : (realEmail.components(separatedBy: "@").first ?? "")
            let displayName = firstName.isEmpty ? emailPrefix : firstName

            // Detect whether the user already has local guest data BEFORE we register the
            // account, so signIn() can flag the migrate-vs-discard prompt.
            let hadGuestData = !session.guestStore.inventoryItems.isEmpty
                            || !session.guestStore.groceryItems.isEmpty
                            || !session.guestStore.userRecipes.isEmpty

            // Register the account (accountType -> .registered, sync enabled, wasGuest cleared).
            // The old code called enterKitchen(), which forced accountType back to .guest.
            session.signIn(appleUserID: userID, name: displayName, hadGuestData: hadGuestData)

            // Ask for a name when we couldn't derive a real one from Apple.
            if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                session.pendingAppleNamePrompt = true
            }

            // FR-01 FIX (point 4): do NOT auto-restore. If this device has no local data and the
            // Apple ID has an iCloud backup, OFFER to restore — RootView prompts, and only a "yes"
            // pulls it. When local guest data exists, the migrate/discard prompt handles that
            // instead; the user can still restore later from Settings.
            if !hadGuestData {
                // transferManager is session-owned, so the async task isn't orphaned.
                Task { @MainActor in
                    if await session.transferManager.latestBackupExists() {
                        session.pendingICloudRestoreOffer = true
                    }
                }
            }

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
