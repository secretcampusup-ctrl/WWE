import Foundation

/// Robust WebDAV client: PROPFIND listing, basic auth, self-signed SSL, PikPak DAV hosts.
final class WebDAVClient: NSObject {
    private let server: WebDAVServer
    private var authUsername: String
    private var authPassword: String

    init(server: WebDAVServer) {
        self.server = server
        self.authUsername = server.username
        self.authPassword = server.password
        super.init()
    }

    // MARK: - Public

    func testConnection() async throws {
        _ = try await listFiles(at: "")
    }

    func listFiles(at path: String, forceRefresh: Bool = false) async throws -> [WebDAVFile] {
        let url = try makeRequestURL(relativePath: path, isCollection: true)
        var request = URLRequest(url: url)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy
        if forceRefresh {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        // Some DAV servers (incl. PikPak) expect a trailing slash on collections
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.httpBody = Self.propfindBody
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.serverError
        }

        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Retry once with alternate path conventions for PikPak-style roots
            if http.statusCode == 404 || http.statusCode == 405 {
                if let alt = try? await listFilesAlternateRoot(originalPath: path) {
                    return alt
                }
            }
            throw WebDAVError.http(http.statusCode, snippet: String(body.prefix(160)))
        }

        let files = WebDAVXMLParser().parse(
            data: data,
            basePath: path,
            serverPathPrefix: serverPathPrefix()
        )
        return files.filter { !$0.name.isEmpty && $0.name != "." && $0.name != ".." }
    }

    /// Streaming URL for a file (no credentials in the URL — use `streamHeaders()`).
    func streamURL(for file: WebDAVFile) -> URL? {
        let pathPart = normalizePath(file.path)

        var components = URLComponents()
        components.scheme = server.useHTTPS ? "https" : "http"
        components.host = cleanHost(server.host)
        let port = server.port
        if server.useHTTPS {
            if port != 443 && port != 0 { components.port = port }
        } else {
            if port != 80 && port != 0 { components.port = port }
        }

        // Properly encode each path segment (spaces, unicode, #, etc.)
        let trimmed = pathPart.hasSuffix("/") ? String(pathPart.dropLast()) : pathPart
        if trimmed == "/" || trimmed.isEmpty {
            components.path = "/"
        } else {
            let segs = trimmed.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }
            components.percentEncodedPath = "/" + segs.joined(separator: "/")
        }

        // Do NOT put user:pass in the URL. Special characters break AVFoundation / poster
        // generation. Auth is always sent via streamHeaders() Authorization.
        if let url = components.url {
            return url
        }

        // Manual fallback (still no credentials in URL)
        let scheme = server.useHTTPS ? "https" : "http"
        let portPart: String = {
            if server.useHTTPS && (port == 443 || port == 0) { return "" }
            if !server.useHTTPS && (port == 80 || port == 0) { return "" }
            return ":\(port)"
        }()
        let encodedPath: String = {
            let trimmed = pathPart.hasSuffix("/") ? String(pathPart.dropLast()) : pathPart
            if trimmed == "/" || trimmed.isEmpty { return "/" }
            let segs = trimmed.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }
            return "/" + segs.joined(separator: "/")
        }()
        return URL(string: "\(scheme)://\(cleanHost(server.host))\(portPart)\(encodedPath)")
    }

    /// Cloud-relative path used to match this DAV entry with the same file in
    /// PikPak's native API. Preserve the real folder/file names while removing
    /// only the configured WebDAV root.
    func relativePathComponents(for file: WebDAVFile) -> [String] {
        var path = normalizePath(file.path)
        let prefix = serverPathPrefix()
        if prefix != "/" {
            if path == prefix {
                path = "/"
            } else if path.hasPrefix(prefix + "/") {
                path = String(path.dropFirst(prefix.count))
            }
        }
        return path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
    }

    /// HTTP headers AVPlayer must send for authenticated WebDAV GET / Range requests.
    /// Resolves WebDAV redirects before playback so PikPak's signed CDN URL
    /// reaches AVPlayer/VLC directly. This also prevents Authorization headers
    /// from being lost when the player follows a cross-host redirect itself.
    func resolvedStreamURL(for file: WebDAVFile) async -> URL? {
        guard let originalURL = streamURL(for: file) else { return nil }

        // Capture PikPak's signed Location header without following it. Following
        // the redirect here can make URLSession start the media transfer itself,
        // while the player then opens a second request and may receive an expired
        // or rejected stream.
        let delegate = WebDAVRedirectResolverDelegate(
            username: authUsername,
            password: authPassword,
            originalHost: originalURL.host
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .video
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let resolverSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { resolverSession.finishTasksAndInvalidate() }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("VideoPlayer/1.0 (iOS; WebDAV)", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        do {
            let (_, response) = try await resolverSession.data(for: request)
            if let signedURL = delegate.redirectURL { return signedURL }
            guard let http = response as? HTTPURLResponse,
                  (200...399).contains(http.statusCode) else { return originalURL }
            return response.url ?? originalURL
        } catch {
            // The redirect delegate deliberately stops URLSession before the CDN
            // body is downloaded; the captured signed URL is still valid.
            return delegate.redirectURL ?? originalURL
        }
    }

    func streamHeaders() -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "VideoPlayer/1.0 (iOS; AVPlayer; WebDAV)",
            "Accept": "*/*"
        ]
        if !authUsername.isEmpty {
            headers["Authorization"] = basicAuthHeader()
        }
        return headers
    }

    func delete(file: WebDAVFile) async throws {
        let url = try makeRequestURL(relativePath: file.path, isCollection: file.isDirectory)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.serverError
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WebDAVError.http(http.statusCode, snippet: String(body.prefix(160)))
        }
    }

    // MARK: - URL building

    private func cleanHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
        h = h.replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
        // strip trailing slash / path if user pasted full URL into host field
        if let slash = h.firstIndex(of: "/") {
            h = String(h[..<slash])
        }
        if let at = h.firstIndex(of: "@") {
            h = String(h[h.index(after: at)...])
        }
        if let colon = h.firstIndex(of: ":"),
           h[h.index(after: colon)...].allSatisfy({ $0.isNumber }) {
            h = String(h[..<colon])
        }
        return h.lowercased()
    }

    private func serverPathPrefix() -> String {
        var p = server.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        if p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }

    private func makeRequestURL(relativePath: String, isCollection: Bool) throws -> URL {
        var path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = serverPathPrefix()
        } else if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if let u = URL(string: path) { return u }
        } else if !path.hasPrefix("/") {
            let root = serverPathPrefix()
            path = root == "/" ? "/\(path)" : "\(root)/\(path)"
        }

        path = normalizePath(path)
        // Collections usually need a trailing slash for PROPFIND on strict servers
        if isCollection && !path.hasSuffix("/") {
            path += "/"
        }

        var c = URLComponents()
        c.scheme = server.useHTTPS ? "https" : "http"
        c.host = cleanHost(server.host)
        let port = server.port
        if server.useHTTPS {
            if port != 443 && port != 0 { c.port = port }
        } else {
            if port != 80 && port != 0 { c.port = port }
        }
        c.path = path.hasSuffix("/") ? String(path.dropLast()) + "/" : path
        // URLComponents path should not force-encode slash; set percentEncodedPath carefully
        if path != "/" {
            // Keep trailing slash in percentEncodedPath
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let segs = trimmed.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }
            c.percentEncodedPath = "/" + segs.joined(separator: "/") + (isCollection ? "/" : "")
        } else {
            c.path = "/"
        }

        guard let url = c.url else { throw WebDAVError.invalidURL }
        return url
    }

    private func normalizePath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("http://") || p.hasPrefix("https://"), let u = URL(string: p) {
            p = u.path
        }
        p = p.removingPercentEncoding ?? p
        if !p.hasPrefix("/") { p = "/" + p }
        while p.contains("//") {
            p = p.replacingOccurrences(of: "//", with: "/")
        }
        return p
    }

    private func basicAuthHeader() -> String {
        let creds = "\(authUsername):\(authPassword)"
        let data = Data(creds.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    /// Try common alternate roots when the configured path 404s (esp. PikPak DAV).
    private func listFilesAlternateRoot(originalPath: String) async throws -> [WebDAVFile]? {
        let candidates: [String] = {
            var set: [String] = []
            let current = serverPathPrefix()
            for p in ["/", "/dav", "/webdav", "/remote.php/dav", "/remote.php/webdav"] {
                if p != current { set.append(p) }
            }
            // Username-as-path segment sometimes used
            if !authUsername.isEmpty {
                set.append("/\(authUsername)")
                set.append("/dav/\(authUsername)")
            }
            return set
        }()

        for candidate in candidates {
            var altServer = server
            altServer.path = candidate
            let alt = WebDAVClient(server: altServer)
            do {
                let files = try await alt.listFilesDirect(at: originalPath.isEmpty ? "" : originalPath, forceRefresh: true)
                return files
            } catch {
                continue
            }
        }
        return nil
    }

    /// Direct list without alternate-root recursion.
    private func listFilesDirect(at path: String, forceRefresh: Bool = false) async throws -> [WebDAVFile] {
        let url = try makeRequestURL(relativePath: path, isCollection: true)
        var request = URLRequest(url: url)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy
        if forceRefresh {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = Self.propfindBody
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.serverError }
        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            throw WebDAVError.http(http.statusCode, snippet: "")
        }
        return WebDAVXMLParser().parse(data: data, basePath: path, serverPathPrefix: serverPathPrefix())
            .filter { !$0.name.isEmpty && $0.name != "." && $0.name != ".." }
    }

    private static let propfindBody: Data = {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getcontenttype/>
            <D:getlastmodified/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """
        return Data(xml.utf8)
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.networkServiceType = .responsiveData // PROPFIND/metadata should remain responsive beside video transfers.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": "VideoPlayer/1.0 (WebDAV; iOS)"
        ]
        return URLSession(configuration: config, delegate: AuthSSLDelegate(username: authUsername, password: authPassword), delegateQueue: nil)
    }()
}

// MARK: - XML Parser

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var files: [WebDAVFile] = []
    private var currentElement = ""
    private var currentHref = ""
    private var currentName = ""
    private var currentSize: Int64?
    private var currentType = ""
    private var currentIsDir = false
    private var isFirstEntry = true
    private var basePath = ""
    private var serverPathPrefix = ""

    func parse(data: Data, basePath: String, serverPathPrefix: String) -> [WebDAVFile] {
        self.basePath = basePath
        self.serverPathPrefix = serverPathPrefix
        files = []
        isFirstEntry = true
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return files
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        currentElement = local.lowercased()

        if currentElement == "response" {
            currentHref = ""
            currentName = ""
            currentSize = nil
            currentType = ""
            currentIsDir = false
        }
        if currentElement == "collection" {
            currentIsDir = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch currentElement {
        case "href":
            currentHref += trimmed
        case "displayname":
            currentName += trimmed
        case "getcontentlength":
            currentSize = Int64(trimmed)
        case "getcontenttype":
            currentType += trimmed
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        guard local == "response" else { return }

        if isFirstEntry {
            isFirstEntry = false
        }

        let decodedHref = currentHref.removingPercentEncoding ?? currentHref
        var path = decodedHref
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let u = URL(string: path) {
            path = u.path
        }
        if !path.hasPrefix("/") { path = "/" + path }

        var name = currentName
        if name.isEmpty {
            name = (path as NSString).lastPathComponent
        }
        name = name.removingPercentEncoding ?? name
        guard !name.isEmpty else { return }

        let normalizedBase: String = {
            var b = basePath
            if b.isEmpty { b = serverPathPrefix }
            if !b.hasPrefix("/") { b = "/" + b }
            if b.count > 1 && b.hasSuffix("/") { b = String(b.dropLast()) }
            return b
        }()
        var normalizedPath = path
        if normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath = String(normalizedPath.dropLast())
        }
        if normalizedPath == normalizedBase || normalizedPath == serverPathPrefix {
            return
        }

        let file = WebDAVFile(
            name: name,
            path: path,
            isDirectory: currentIsDir,
            size: currentIsDir ? nil : currentSize,
            contentType: currentType.isEmpty ? nil : currentType
        )
        files.append(file)
    }
}

// MARK: - Signed stream redirect resolver

private final class WebDAVRedirectResolverDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let username: String
    private let password: String
    private let originalHost: String?
    private let lock = NSLock()
    private var capturedRedirectURL: URL?

    var redirectURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRedirectURL
    }

    init(username: String, password: String, originalHost: String?) {
        self.username = username
        self.password = password
        self.originalHost = originalHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let destinationHost = request.url?.host
        let remainsOnDAVHost = destinationHost?.caseInsensitiveCompare(originalHost ?? "") == .orderedSame

        if remainsOnDAVHost {
            // Follow URL normalization/auth redirects inside the DAV server. iOS
            // may remove Authorization while rebuilding the redirect request, so
            // explicitly restore it for the next DAV hop.
            var authenticatedRequest = request
            if !username.isEmpty {
                let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
                authenticatedRequest.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            }
            authenticatedRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            completionHandler(authenticatedRequest)
            return
        }

        lock.lock()
        capturedRedirectURL = request.url
        lock.unlock()
        // Stop only at the cross-host CDN hop. The player opens that final signed
        // URL itself, without leaking the WebDAV Authorization header.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // The resolver needs headers/redirects only. Never allow data(for:) to
        // buffer the media body when a DAV server responds with 200/206 directly
        // instead of redirecting to a CDN URL.
        completionHandler(.cancel)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if method == NSURLAuthenticationMethodHTTPBasic
                    || method == NSURLAuthenticationMethodDefault {
            completionHandler(
                .useCredential,
                URLCredential(user: username, password: password, persistence: .forSession)
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - SSL + Basic Auth challenge

final class AuthSSLDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let username: String
    let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodDefault {
            if challenge.previousFailureCount > 1 {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let cred = URLCredential(user: username, password: password, persistence: .forSession)
            completionHandler(.useCredential, cred)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// Legacy alias
typealias SSLDelegate = AuthSSLDelegate

// MARK: - Errors

enum WebDAVError: LocalizedError {
    case invalidURL
    case serverError
    case parseError
    case notFound
    case http(Int, snippet: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid WebDAV server address"
        case .serverError: return "Could not connect to the WebDAV server"
        case .parseError: return "Could not read WebDAV response"
        case .notFound: return "File not found"
        case .http(let code, let snippet):
            if code == 401 || code == 403 {
                return "WebDAV auth failed (HTTP \(code)). Check username/password."
            }
            if code == 404 {
                return "WebDAV path not found (HTTP 404). Try Path `/` or `/dav` (PikPak: often `/`)."
            }
            let extra = snippet.isEmpty ? "" : " — \(snippet)"
            return "WebDAV error HTTP \(code)\(extra)"
        }
    }
}

// MARK: - Server paste / preset helpers

extension WebDAVServer {
    /// Parse a pasted host / full URL / user:pass@host into connection fields.
    static func parseConnectionString(_ raw: String) -> (
        host: String,
        port: Int?,
        path: String?,
        username: String?,
        password: String?,
        useHTTPS: Bool?
    ) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var useHTTPS: Bool? = nil
        var username: String? = nil
        var password: String? = nil
        var port: Int? = nil
        var path: String? = nil

        let lower = text.lowercased()
        if lower.hasPrefix("https://") {
            useHTTPS = true
            text = String(text.dropFirst(8))
        } else if lower.hasPrefix("http://") {
            useHTTPS = false
            text = String(text.dropFirst(7))
        }

        // user:pass@host…
        if let at = text.firstIndex(of: "@") {
            let credPart = String(text[..<at])
            text = String(text[text.index(after: at)...])
            if let colon = credPart.firstIndex(of: ":") {
                username = String(credPart[..<colon])
                password = String(credPart[credPart.index(after: colon)...])
            } else {
                username = credPart
            }
        }

        // host:port/path or host/path
        var hostPart = text
        if let slash = text.firstIndex(of: "/") {
            path = String(text[slash...])
            hostPart = String(text[..<slash])
        }
        if let colon = hostPart.lastIndex(of: ":"),
           let p = Int(hostPart[hostPart.index(after: colon)...]) {
            port = p
            hostPart = String(hostPart[..<colon])
        }

        return (
            host: hostPart.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            path: path,
            username: username,
            password: password,
            useHTTPS: useHTTPS
        )
    }

    static func pikpakDAVPreset(username: String, password: String, useHTTPS: Bool = true) -> WebDAVServer {
        WebDAVServer(
            name: "PikPak WebDAV",
            host: "dav.mypikpak.com",
            port: useHTTPS ? 443 : 80,
            path: "/",
            username: username,
            password: password,
            useHTTPS: useHTTPS
        )
    }
}
