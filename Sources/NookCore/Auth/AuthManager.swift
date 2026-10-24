import Foundation
import AuthenticationServices
import FirebaseAuth

/// Error types for authentication operations.
public enum AuthError: LocalizedError, Sendable {
    case notAuthenticated
    case signInFailed(String)
    case tokenRefreshFailed
    case cancelled
    case firebaseNotConfigured
    
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User is not authenticated. Please sign in."
        case .signInFailed(let reason):
            return "Sign in failed: \(reason)"
        case .tokenRefreshFailed:
            return "Failed to refresh authentication token."
        case .cancelled:
            return "Sign in was cancelled."
        case .firebaseNotConfigured:
            return "Firebase is not configured. Add GoogleService-Info.plist to your app."
        }
    }
}

/// Represents an authenticated user.
public struct AuthenticatedUser: Sendable, Equatable {
    public let uid: String
    public let email: String?
    public let displayName: String?

    public init(uid: String, email: String?, displayName: String?) {
        self.uid = uid
        self.email = email
        self.displayName = displayName
    }
}

/// Manages user authentication with Firebase Auth.
///
/// This is a protocol-based design to allow for:
/// - Real Firebase Auth implementation
/// - Mock implementation for testing
/// - Future alternative auth providers
public protocol AuthProviding: Sendable {
    /// The currently authenticated user, or nil if not signed in.
    var currentUser: AuthenticatedUser? { get async }

    /// Whether a user is currently authenticated.
    var isAuthenticated: Bool { get async }
    
    /// Whether the current user is anonymous.
    var isAnonymous: Bool { get async }

    /// Get a fresh ID token for API calls.
    func getIDToken() async throws -> String
    
    /// Sign in anonymously (no user interaction required).
    func signInAnonymously() async throws -> AuthenticatedUser

    /// Sign in with Apple credential.
    func signInWithApple(
        idToken: String,
        nonce: String,
        fullName: PersonNameComponents?
    ) async throws -> AuthenticatedUser

    /// Sign out the current user.
    func signOut() async throws
}

/// Main authentication manager that coordinates auth operations.
@MainActor
public final class AuthManager: ObservableObject {
    @Published public private(set) var currentUser: AuthenticatedUser?
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var isAnonymous: Bool = false
    @Published public private(set) var isLoading: Bool = false

    private let provider: any AuthProviding
    private var currentNonce: String?

    public init(provider: any AuthProviding) {
        self.provider = provider
        Task {
            await refreshAuthState()
        }
    }

    /// Refresh the current auth state from the provider.
    public func refreshAuthState() async {
        currentUser = await provider.currentUser
        isAuthenticated = await provider.isAuthenticated
        isAnonymous = await provider.isAnonymous
    }

    /// Get a fresh ID token for API calls.
    public func getIDToken() async throws -> String {
        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }
        return try await provider.getIDToken()
    }
    
    /// Ensure the user is authenticated, signing in anonymously if needed.
    /// Call this on app launch to guarantee a valid auth session.
    public func ensureAuthenticated() async throws {
        await refreshAuthState()
        if !isAuthenticated {
            isLoading = true
            defer { isLoading = false }
            let user = try await provider.signInAnonymously()
            currentUser = user
            isAuthenticated = true
            isAnonymous = true
        }
    }
    
    /// Sign in anonymously. Returns the authenticated user.
    public func signInAnonymously() async throws -> AuthenticatedUser {
        isLoading = true
        defer { isLoading = false }
        
        let user = try await provider.signInAnonymously()
        currentUser = user
        isAuthenticated = true
        isAnonymous = true
        return user
    }

    /// Generate a nonce for Sign in with Apple.
    public func prepareSignInWithApple() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return nonce
    }

    /// Complete Sign in with Apple after receiving the credential.
    public func completeSignInWithApple(
        credential: ASAuthorizationAppleIDCredential
    ) async throws {
        isLoading = true
        defer { isLoading = false }

        guard let nonce = currentNonce else {
            throw AuthError.signInFailed("Missing nonce. Call prepareSignInWithApple() first.")
        }

        guard let identityToken = credential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.signInFailed("Unable to get identity token from Apple.")
        }

        let user = try await provider.signInWithApple(
            idToken: idTokenString,
            nonce: nonce,
            fullName: credential.fullName
        )

        currentUser = user
        isAuthenticated = true
        currentNonce = nil
    }

    /// Sign out the current user.
    public func signOut() async throws {
        try await provider.signOut()
        currentUser = nil
        isAuthenticated = false
    }

    // MARK: - Private Helpers

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }

        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }
        return String(nonce)
    }
}

// MARK: - Firebase Auth Provider

/// Real Firebase Auth provider for production use.
public actor FirebaseAuthProvider: AuthProviding {
    
    public init() {}
    
    public var currentUser: AuthenticatedUser? {
        guard let user = Auth.auth().currentUser else { return nil }
        return AuthenticatedUser(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName
        )
    }
    
    public var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }
    
    public var isAnonymous: Bool {
        Auth.auth().currentUser?.isAnonymous ?? false
    }
    
    public func getIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }
        do {
            return try await user.getIDToken()
        } catch {
            throw AuthError.tokenRefreshFailed
        }
    }
    
    public func signInAnonymously() async throws -> AuthenticatedUser {
        do {
            let result = try await Auth.auth().signInAnonymously()
            return AuthenticatedUser(
                uid: result.user.uid,
                email: nil,
                displayName: nil
            )
        } catch {
            throw AuthError.signInFailed(error.localizedDescription)
        }
    }
    
    public func signInWithApple(
        idToken: String,
        nonce: String,
        fullName: PersonNameComponents?
    ) async throws -> AuthenticatedUser {
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: fullName
        )
        
        do {
            // If currently anonymous, link the Apple credential to upgrade the account
            if let currentUser = Auth.auth().currentUser, currentUser.isAnonymous {
                let result = try await currentUser.link(with: credential)
                return AuthenticatedUser(
                    uid: result.user.uid,
                    email: result.user.email,
                    displayName: result.user.displayName ?? fullName?.formatted()
                )
            } else {
                // Otherwise, sign in fresh
                let result = try await Auth.auth().signIn(with: credential)
                return AuthenticatedUser(
                    uid: result.user.uid,
                    email: result.user.email,
                    displayName: result.user.displayName ?? fullName?.formatted()
                )
            }
        } catch {
            throw AuthError.signInFailed(error.localizedDescription)
        }
    }
    
    public func signOut() async throws {
        do {
            try Auth.auth().signOut()
        } catch {
            throw AuthError.signInFailed(error.localizedDescription)
        }
    }
}

// MARK: - Mock Auth Provider for Development/Testing

/// Mock auth provider for development and testing.
public actor MockAuthProvider: AuthProviding {
    private var user: AuthenticatedUser?
    private var token: String?
    private var anonymous: Bool = false

    public init(preAuthenticatedUser: AuthenticatedUser? = nil) {
        self.user = preAuthenticatedUser
        if preAuthenticatedUser != nil {
            self.token = "mock-token-\(UUID().uuidString)"
        }
    }

    public var currentUser: AuthenticatedUser? {
        user
    }

    public var isAuthenticated: Bool {
        user != nil
    }
    
    public var isAnonymous: Bool {
        anonymous
    }

    public func getIDToken() async throws -> String {
        guard let token else {
            throw AuthError.notAuthenticated
        }
        return token
    }
    
    public func signInAnonymously() async throws -> AuthenticatedUser {
        let newUser = AuthenticatedUser(
            uid: "anon-\(UUID().uuidString)",
            email: nil,
            displayName: nil
        )
        self.user = newUser
        self.token = "mock-anon-token-\(UUID().uuidString)"
        self.anonymous = true
        return newUser
    }

    public func signInWithApple(
        idToken: String,
        nonce: String,
        fullName: PersonNameComponents?
    ) async throws -> AuthenticatedUser {
        let newUser = AuthenticatedUser(
            uid: "mock-uid-\(UUID().uuidString)",
            email: "mock@example.com",
            displayName: fullName?.formatted() ?? "Mock User"
        )
        self.user = newUser
        self.token = "mock-token-\(UUID().uuidString)"
        self.anonymous = false
        return newUser
    }

    public func signOut() async throws {
        user = nil
        token = nil
        anonymous = false
    }
}
