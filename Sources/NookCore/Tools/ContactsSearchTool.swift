import Contacts
import Foundation

public struct ContactSnapshot: Sendable {
    public let fullName: String
    public let emails: [String]
    public let phones: [String]
    public let organization: String?

    public init(
        fullName: String,
        emails: [String] = [],
        phones: [String] = [],
        organization: String? = nil
    ) {
        self.fullName = fullName
        self.emails = emails
        self.phones = phones
        self.organization = organization
    }
}

public protocol ContactSearching: Sendable {
    func requestAccess() async throws -> Bool
    func search(query: String) async throws -> [ContactSnapshot]
}

public final class CNContactSearcher: @unchecked Sendable, ContactSearching {
    public init() {}

    public func requestAccess() async throws -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        return try await CNContactStore().requestAccess(for: .contacts)
    }

    public func search(query: String) async throws -> [ContactSnapshot] {
        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        let queryLower = query.lowercased()
        var results: [ContactSnapshot] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let org = contact.organizationName
            let emails = contact.emailAddresses.map { $0.value as String }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            let haystack = ([name, org] + emails + phones)
                .joined(separator: " ").lowercased()
            guard haystack.contains(queryLower) else { return }
            results.append(ContactSnapshot(
                fullName: name,
                emails: emails,
                phones: phones,
                organization: org.isEmpty ? nil : org
            ))
        }
        return Array(results.prefix(10))
    }
}

/// On-device Contacts search — registered as `contacts.search`.
public final class ContactsSearchTool: @unchecked Sendable, AgentTool {
    public static let toolName = "contacts.search"

    public var name: String { Self.toolName }
    public let description = """
        Search the user's contacts by name, email, or phone. \
        Use when the user asks for someone's contact details, email, or phone number.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "query",
            type: "string",
            description: "Name, email address, or phone number to search for.",
            required: true
        ),
    ]

    private let searcher: any ContactSearching

    public init(searcher: any ContactSearching = CNContactSearcher()) {
        self.searcher = searcher
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let query = (arguments["query"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolExecutionResult(
                textForModel: "contacts.search requires a query.",
                displayText: "\(Self.toolName) · missing query",
                disposition: .needsUser
            )
        }

        let granted: Bool
        do {
            granted = try await searcher.requestAccess()
        } catch {
            return ToolExecutionResult(
                textForModel: "Contacts access failed: \(error.localizedDescription). Ask the user to allow Contacts for Nook in Settings.",
                displayText: "\(Self.toolName) · access failed",
                disposition: .needsUser
            )
        }
        guard granted else {
            return ToolExecutionResult(
                textForModel: "The user has not allowed Contacts access. Ask them to enable Contacts for Nook in Settings.",
                displayText: "\(Self.toolName) · permission denied",
                disposition: .needsUser
            )
        }

        let contacts: [ContactSnapshot]
        do {
            contacts = try await searcher.search(query: query)
        } catch {
            return ToolExecutionResult(
                textForModel: "Could not search contacts: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }

        guard !contacts.isEmpty else {
            return ToolExecutionResult(
                textForModel: "No contacts found for \"\(query)\".",
                displayText: "\(Self.toolName) · 0 results"
            )
        }

        let lines = contacts.map { c -> String in
            var parts = [c.fullName]
            if let org = c.organization { parts.append(org) }
            if let email = c.emails.first { parts.append(email) }
            if let phone = c.phones.first { parts.append(phone) }
            return "• " + parts.joined(separator: " · ")
        }
        let count = contacts.count

        return ToolExecutionResult(
            textForModel: """
            Found \(count) contact(s) for "\(query)":
            \(lines.joined(separator: "\n"))
            """,
            displayText: "\(Self.toolName) · \(count) result\(count == 1 ? "" : "s")"
        )
    }
}
