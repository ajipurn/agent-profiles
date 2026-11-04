import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared request plumbing for providers: one JSON GET or POST, with 401
/// and 403 reported as `.unauthorized`.
public enum ProviderHTTP {
    public static func json(_ request: URLRequest, in environment: ProviderEnvironment) async throws -> Any {
        let (data, response) = try await environment.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFetchError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ProviderFetchError.unauthorized
        default: throw ProviderFetchError.http(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw ProviderFetchError.invalidResponse }
        return object
    }

    public static func object(_ request: URLRequest, in environment: ProviderEnvironment) async throws -> [String: Any] {
        guard let object = try await json(request, in: environment) as? [String: Any] else {
            throw ProviderFetchError.invalidResponse
        }
        return object
    }

    /// A request with `Accept: application/json`, a 20 s timeout and no caching.
    public static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                               jsonBody: Any? = nil, formBody: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let jsonBody, let data = try? JSONSerialization.data(withJSONObject: jsonBody) {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let formBody {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            request.httpBody = formBody
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

/// Lenient readers for JSON values that arrive as numbers or strings.
public enum ProviderJSON {
    public static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value.isFinite ? value : nil
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    public static func string(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: ["true", "1", "yes"].contains(value.lowercased()) ? true : ["false", "0", "no"].contains(value.lowercased()) ? false : nil
        default: nil
        }
    }

    /// ISO 8601 (with or without fractional seconds), "YYYY-MM-DD", or Unix
    /// seconds / milliseconds.
    public static func date(_ value: Any?) -> Date? {
        if let text = string(value) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withFullDate]
            if let date = iso.date(from: text) { return date }
            if let number = Double(text) { return unix(number) }
            return nil
        }
        return double(value).map(unix)
    }

    private static func unix(_ number: Double) -> Date {
        Date(timeIntervalSince1970: abs(number) > 1e11 ? number / 1000 : number)
    }

    /// The claims of a JWT, unverified (identity display only).
    public static func jwtClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func readObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
