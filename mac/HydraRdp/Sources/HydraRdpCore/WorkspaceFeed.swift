import Foundation

public struct WorkspaceFeedItem: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var feedURL: URL

    public init(id: String, name: String, feedURL: URL) {
        self.id = id
        self.name = name
        self.feedURL = feedURL
    }
}

public struct WorkspaceResource: Equatable, Identifiable {
    public enum Kind: String, Equatable {
        case desktop
        case cloudPC
        case remoteApp
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var rdpFileURL: URL?
    public var rdpContents: String?

    public init(id: String, name: String, kind: Kind, rdpFileURL: URL?, rdpContents: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rdpFileURL = rdpFileURL
        self.rdpContents = rdpContents
    }
}

public enum WorkspaceFeed {
    public static let discoveryURL = URL(string: "https://rdweb.wvd.microsoft.com/api/arm/feeddiscovery")!
    public static let defaultUserAgent = AppPreferences.defaultFeedUserAgent
    public static let discoveryAccept = "application/x-msts-radc-discovery+xml,text/xml"
    public static let feedAccept = "application/x-msts-radc+xml;radc_schema_version=2.0,text/xml"

    public static func parseDiscovery(_ data: Data, sourceURL: URL = discoveryURL) throws -> [WorkspaceFeedItem] {
        if looksLikeXML(data) {
            return try discoveryFromXML(data, sourceURL: sourceURL)
        }
        let json = try jsonObject(data)
        let rows = arrayPayload(json)
        return rows.compactMap(feedItem)
    }

    public static func parseResources(_ data: Data, baseURL: URL? = nil) throws -> [WorkspaceResource] {
        if looksLikeXML(data) {
            return try resourcesFromXML(data, baseURL: baseURL)
        }
        let json = try jsonObject(data)
        if let rows = json as? [[String: Any]] {
            return rows.compactMap { resource($0) }
        }
        guard let object = json as? [String: Any] else { return [] }
        var found: [WorkspaceResource] = []
        let groupedKeys = ["RemoteDesktop", "RemoteApp", "CloudPC", "Resources", "value", "Items", "items"]
        for key in object.keys {
            let matches = groupedKeys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
            guard matches, let rows = object[key] as? [[String: Any]] else { continue }
            let hinted = kindHint(key)
            found.append(contentsOf: rows.compactMap { resource($0, hinted: hinted) })
        }
        if found.isEmpty, let nested = object["properties"] as? [String: Any] {
            let encoded = try JSONSerialization.data(withJSONObject: nested)
            return try parseResources(encoded, baseURL: baseURL)
        }
        return found
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WorkspaceClientError("The workspace feed was not in a readable format.")
        }
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return true }
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        guard let prefix = String(data: body.prefix(64), encoding: .utf8) else { return false }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    private static func discoveryFromXML(_ data: Data, sourceURL: URL) throws -> [WorkspaceFeedItem] {
        let document = try FeedXMLDocument(data: data, baseURL: sourceURL)
        if !document.feeds.isEmpty { return document.feeds }
        guard !document.resources.isEmpty else { return [] }
        let name = document.publisherName.isEmpty ? (sourceURL.host ?? "Workspace") : document.publisherName
        let id = document.publisherID.isEmpty ? sourceURL.absoluteString : document.publisherID
        return [WorkspaceFeedItem(id: id, name: name, feedURL: sourceURL)]
    }

    private static func resourcesFromXML(_ data: Data, baseURL: URL?) throws -> [WorkspaceResource] {
        try FeedXMLDocument(data: data, baseURL: baseURL).resources
    }

    private static func arrayPayload(_ json: Any) -> [[String: Any]] {
        if let rows = json as? [[String: Any]] { return rows }
        guard let object = json as? [String: Any] else { return [] }
        for key in ["value", "feeds", "Items", "items"] {
            if let rows = value(object, key) as? [[String: Any]] { return rows }
        }
        return [object]
    }

    private static func feedItem(_ object: [String: Any]) -> WorkspaceFeedItem? {
        let urlString = string(object, ["FeedUrl", "feedUrl", "Url", "url"])
            ?? nestedString(object, "properties", ["feedUrl", "FeedUrl", "url"])
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let name = string(object, ["FriendlyName", "FeedName", "name", "Name"]) ?? url.host ?? "Workspace"
        let id = string(object, ["WorkspaceId", "TenantId", "id", "Id"]) ?? url.absoluteString
        return WorkspaceFeedItem(id: id, name: name, feedURL: url)
    }

    private static func resource(_ object: [String: Any], hinted: WorkspaceResource.Kind? = nil) -> WorkspaceResource? {
        let name = string(object, ["Name", "name", "FriendlyName", "DisplayName"]) ?? "Resource"
        let id = string(object, ["Id", "id", "ResourceId"]) ?? name
        let typeText = string(object, ["Type", "type", "ResourceType", "resourceType"]) ?? ""
        let kind = kind(from: typeText) ?? hinted ?? .desktop
        let urlString = string(object, ["RdpFileUrl", "rdpFileUrl", "RdpUrl", "rdpUrl"])
        let contents = string(object, ["RdpFileContents", "rdpFileContents", "RdpContents", "rdpContents"])
        if urlString == nil && (contents == nil || contents?.isEmpty == true) && typeText.isEmpty && hinted == nil {
            return nil
        }
        return WorkspaceResource(
            id: id,
            name: name,
            kind: kind,
            rdpFileURL: urlString.flatMap { URL(string: $0) },
            rdpContents: contents
        )
    }

    private static func kind(from text: String) -> WorkspaceResource.Kind? {
        let lowered = text.lowercased()
        if lowered.contains("cloud") { return .cloudPC }
        if lowered.contains("app") { return .remoteApp }
        if lowered.contains("desktop") { return .desktop }
        return nil
    }

    private static func kindHint(_ key: String) -> WorkspaceResource.Kind? {
        kind(from: key)
    }

    private static func string(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = value(object, key) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func nestedString(_ object: [String: Any], _ parent: String, _ keys: [String]) -> String? {
        guard let child = value(object, parent) as? [String: Any] else { return nil }
        return string(child, keys)
    }

    private static func value(_ object: [String: Any], _ key: String) -> Any? {
        for (candidate, value) in object where candidate.caseInsensitiveCompare(key) == .orderedSame {
            return value
        }
        return nil
    }
}

public struct WorkspaceClient {
    public var userAgent: String
    public var session: URLSession

    public init(userAgent: String = WorkspaceFeed.defaultUserAgent, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    public func discover(accessToken: String) async throws -> [WorkspaceFeedItem] {
        let data = try await fetch(
            WorkspaceFeed.discoveryURL,
            accessToken: accessToken,
            accept: WorkspaceFeed.discoveryAccept
        )
        return try WorkspaceFeed.parseDiscovery(data, sourceURL: WorkspaceFeed.discoveryURL)
    }

    public func resources(feedURL: URL, accessToken: String) async throws -> [WorkspaceResource] {
        let data = try await fetch(feedURL, accessToken: accessToken, accept: WorkspaceFeed.feedAccept)
        return try WorkspaceFeed.parseResources(data, baseURL: feedURL)
    }

    public func rdpText(for resource: WorkspaceResource, accessToken: String) async throws -> String {
        if let contents = resource.rdpContents?.trimmingCharacters(in: .whitespacesAndNewlines), !contents.isEmpty {
            return contents
        }
        guard let url = resource.rdpFileURL else {
            throw WorkspaceClientError("This resource has no .rdp file.")
        }
        let data = try await fetch(url, accessToken: accessToken, accept: "*/*")
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(":s:") || trimmed.contains(":i:") {
                return trimmed
            }
            if let embedded = embeddedRdp(in: data) {
                return embedded
            }
            if !trimmed.isEmpty { return trimmed }
        }
        throw WorkspaceClientError("The .rdp download was empty.")
    }

    private func fetch(_ url: URL, accessToken: String, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(userAgent, forHTTPHeaderField: "X-MS-User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WorkspaceClientError("The workspace service did not answer.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkspaceClientError("Workspace request failed (\(http.statusCode)).")
        }
        return data
    }

    private func embeddedRdp(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["RdpFileContents", "rdpFileContents", "rdpContents", "contents", "Content"] {
            if let text = json[key] as? String, text.contains(":s:") || text.contains(":i:") {
                return text
            }
        }
        return nil
    }
}

public struct WorkspaceClientError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Microsoft’s workspace feed is the Remote Desktop XML document (MS-TSWP), sometimes behind an Atom list of feed URLs.
private final class FeedXMLDocument: NSObject, XMLParserDelegate {
    var resources: [WorkspaceResource] = []
    var feeds: [WorkspaceFeedItem] = []
    var publisherName = ""
    var publisherID = ""

    private let baseURL: URL?
    private var text = ""
    private var inResource = false
    private var resourceID = ""
    private var resourceAlias = ""
    private var resourceTitle = ""
    private var resourceType = ""
    private var resourceURL: URL?
    private var inEntry = false
    private var entryTitle = ""
    private var entryURL: URL?
    private var feedTitle = ""

    init(data: Data, baseURL: URL?) throws {
        self.baseURL = baseURL
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw WorkspaceClientError("The workspace feed was not in a readable format.")
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        switch localName(elementName) {
        case "publisher":
            publisherName = first(attributes, "Name") ?? publisherName
            publisherID = first(attributes, "ID", "Id") ?? publisherID
        case "resource":
            inResource = true
            resourceID = first(attributes, "ID", "Id") ?? ""
            resourceAlias = first(attributes, "Alias") ?? ""
            resourceTitle = first(attributes, "Title", "Name") ?? ""
            resourceType = first(attributes, "Type") ?? ""
            resourceURL = url(first(attributes, "ResourceFile", "URL", "Url"))
        case "resourcefile":
            resourceURL = url(first(attributes, "URL", "Url")) ?? resourceURL
        case "entry":
            inEntry = true
            entryTitle = ""
            entryURL = nil
        case "tenantfeedurl":
            let title = first(attributes, "TenantDisplayName", "DisplayName", "Name") ?? feedTitle
            if let href = url(first(attributes, "FeedURL", "FeedUrl", "URL", "Url")) {
                rememberFeed(title: title, url: href)
            }
        case "link":
            let relation = (first(attributes, "rel") ?? "alternate").lowercased()
            guard relation == "alternate" || relation.isEmpty else { return }
            let href = url(first(attributes, "href"))
            if inEntry {
                entryURL = href ?? entryURL
            } else if let href {
                rememberFeed(title: feedTitle, url: href)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "resource":
            finishResource()
        case "title", "name":
            if inResource, resourceTitle.isEmpty { resourceTitle = trimmed }
            else if inEntry { entryTitle = trimmed }
            else if feedTitle.isEmpty { feedTitle = trimmed }
        case "type":
            if inResource, resourceType.isEmpty { resourceType = trimmed }
        case "id":
            if inResource, resourceID.isEmpty { resourceID = trimmed }
            else if inEntry, entryURL == nil { entryURL = httpURL(trimmed) }
        case "content", "tenantfeedurl", "feedurl":
            if let found = httpURL(trimmed) {
                if inEntry { entryURL = entryURL ?? found }
                else { rememberFeed(title: feedTitle, url: found) }
            }
        case "entry":
            if let entryURL { rememberFeed(title: entryTitle, url: entryURL) }
            inEntry = false
        default:
            break
        }
        text = ""
    }

    private func finishResource() {
        let title = resourceTitle.isEmpty ? (resourceAlias.isEmpty ? "Resource" : resourceAlias) : resourceTitle
        let id = resourceID.isEmpty ? (resourceAlias.isEmpty ? title : resourceAlias) : resourceID
        let typeText = resourceType
        let kind = kind(from: typeText) ?? .desktop
        resources.append(WorkspaceResource(
            id: id,
            name: title,
            kind: kind,
            rdpFileURL: resourceURL,
            rdpContents: nil
        ))
        inResource = false
    }

    private func rememberFeed(title: String, url: URL) {
        let absolute = url.absoluteURL
        guard !feeds.contains(where: { $0.feedURL == absolute }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        feeds.append(WorkspaceFeedItem(
            id: absolute.absoluteString,
            name: name.isEmpty ? (absolute.host ?? "Workspace") : name,
            feedURL: absolute
        ))
    }

    private func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map { $0.lowercased() } ?? elementName.lowercased()
    }

    private func first(_ attributes: [String: String], _ keys: String...) -> String? {
        for key in keys {
            guard let value = attributes.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func url(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        return httpURL(raw) ?? relativeURL(raw)
    }

    private func httpURL(_ raw: String) -> URL? {
        guard let parsed = URL(string: raw), parsed.scheme?.hasPrefix("http") == true else { return nil }
        return parsed
    }

    private func relativeURL(_ raw: String) -> URL? {
        guard let baseURL, let relative = URL(string: raw, relativeTo: baseURL) else { return nil }
        return relative.absoluteURL
    }

    private func kind(from text: String) -> WorkspaceResource.Kind? {
        let lowered = text.lowercased()
        if lowered.contains("cloud") { return .cloudPC }
        if lowered.contains("app") { return .remoteApp }
        if lowered.contains("desktop") { return .desktop }
        return nil
    }
}
