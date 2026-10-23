import Foundation
import AuthenticationServices

/// Error types for authentication operations.
public enum AuthError: LocalizedError, Sendable {
    case notAuthenticated
    case signInFailed(String)
    case tokenRefreshFailed
    case cancelled

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

    /// Get a fresh ID token for API calls.
    func getIDToken() async throws -> String

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
    }

    /// Get a fresh ID token for API calls.
    public func getIDToken() async throws -> String {
        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }
        return try await provider.getIDToken()
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

// MARK: - Mock Auth Provider for Development/Testing

/// Mock auth provider for development and testing.
public actor MockAuthProvider: AuthProviding {
    private var user: AuthenticatedUser?
    private var token: String?

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

    public func getIDToken() async throws -> String {
        guard let token else {
            throw AuthError.notAuthenticated
        }
        return token
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
        return newUser
    }

    public func signOut() async throws {
        user = nil
        token = nil
    }
}
