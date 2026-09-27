import Foundation

public struct AccountIdentity: Equatable, Sendable, Codable, Hashable {
    public var accountID: String
    public var email: String?
    public var name: String?
    public var plan: String?
    public var organizations: [String]
    public var authMode: String?

    public init(
        accountID: String,
        email: String? = nil,
        name: String? = nil,
        plan: String? = nil,
        organizations: [String] = [],
        authMode: String? = nil
    ) {
        self.accountID = accountID
        self.email = email
        self.name = name
        self.plan = plan
        self.organizations = organizations
        self.authMode = authMode
    }

    public var title: String {
        if let email, !email.isEmpty { return email }
        if let name, !name.isEmpty { return name }
        if authMode == "apikey" { return "API key" }
        return String(accountID.prefix(8))
    }

    public var subtitle: String {
        var parts: [String] = []
        if let plan, !plan.isEmpty {
            parts.append(Self.displayPlan(plan))
        }
        if let org = organizations.first, !org.isEmpty {
            parts.append(org)
        }
        return parts.joined(separator: " · ")
    }

    public func isSameAccount(as other: AccountIdentity) -> Bool {
        accountID == other.accountID
    }

    public var initials: String {
        let source = name ?? email ?? accountID
        let words = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        let chars = words.prefix(2).compactMap(\.first)
        if chars.isEmpty { return "C" }
        return String(chars).uppercased()
    }

    public static func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "plus": "Plus"
        case "pro": "Pro"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "free", "freeplan": "Free"
        default: plan.localizedCapitalized
        }
    }
}

public enum AccountIdentityParser {
    public static func parse(authJSON data: Data) throws -> AccountIdentity? {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else { return nil }
        return parse(root: object)
    }

    public static func parse(root: [String: Any]) -> AccountIdentity? {
        let authMode = root["auth_mode"] as? String
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let claims = jwtClaims(from: tokens["id_token"] as? String) ?? [:]
        let openaiAuth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accountID =
            nonEmpty(openaiAuth["chatgpt_user_id"])
            ?? nonEmpty(openaiAuth["user_id"])
            ?? nonEmpty(claims["sub"])
            ?? nonEmpty(claims["email"])
            ?? nonEmpty(tokens["account_id"])
            ?? nonEmpty(openaiAuth["chatgpt_account_id"])
        guard let accountID else {
            if authMode == "apikey" || root["OPENAI_API_KEY"] is String {
                return AccountIdentity(accountID: "api-key", authMode: authMode ?? "apikey")
            }
            return nil
        }

        let organizations = (openaiAuth["organizations"] as? [[String: Any]] ?? [])
            .compactMap { $0["title"] as? String }
            .filter { !$0.isEmpty }

        return AccountIdentity(
            accountID: accountID,
            email: nonEmpty(claims["email"]),
            name: nonEmpty(claims["name"]),
            plan: nonEmpty(openaiAuth["chatgpt_plan_type"]),
            organizations: organizations,
            authMode: authMode
        )
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func jwtClaims(from token: String?) -> [String: Any]? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let payload = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var encoded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder > 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: encoded)
    }

    public static func jwtExpiration(from token: String?) -> Date? {
        guard let exp = jwtClaims(from: token)?["exp"] else { return nil }
        if let number = exp as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let value = exp as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = exp as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }
}
