import Foundation

struct ServiceIncident: Identifiable, Equatable, Sendable {
    let provider: Provider
    let id: String
    let title: String
    let status: String
    let impact: String
    let url: URL
}

enum PublicServiceStatus {
    private struct Source: Sendable {
        let url: URL
        let pageURL: URL
        let providers: [Provider]
        let terms: [String]
        let format: Format
    }

    private enum Format: Sendable { case statuspage, googleCloud, xaiRSS }

    private static let sources: [Source] = [
        Source(
            url: URL(string: "https://status.openai.com/api/v2/summary.json")!,
            pageURL: URL(string: "https://status.openai.com")!,
            providers: [.codex], terms: ["codex", "chatgpt", "openai api"], format: .statuspage
        ),
        Source(
            url: URL(string: "https://status.claude.com/api/v2/summary.json")!,
            pageURL: URL(string: "https://status.claude.com")!,
            providers: [.claude], terms: ["claude", "api"], format: .statuspage
        ),
        Source(
            url: URL(string: "https://status.cursor.com/api/v2/summary.json")!,
            pageURL: URL(string: "https://status.cursor.com")!,
            providers: [.cursor], terms: [], format: .statuspage
        ),
        Source(
            url: URL(string: "https://www.githubstatus.com/api/v2/summary.json")!,
            pageURL: URL(string: "https://www.githubstatus.com")!,
            providers: [.copilot], terms: ["copilot"], format: .statuspage
        ),
        Source(
            url: URL(string: "https://status.cloud.google.com/incidents.json")!,
            pageURL: URL(string: "https://status.cloud.google.com")!,
            providers: [.gemini, .antigravity],
            terms: ["gemini", "code assist", "vertex ai"], format: .googleCloud
        ),
        Source(
            url: URL(string: "https://status.x.ai/feed.xml")!,
            pageURL: URL(string: "https://status.x.ai")!,
            providers: [.grok], terms: ["grok", "xai"], format: .xaiRSS
        )
    ]

    static func fetch(for providers: Set<Provider>) async -> [Provider: [ServiceIncident]] {
        let requestedSources = sources.filter { $0.providers.contains(where: providers.contains) }
        return await withTaskGroup(of: (Source, [ServiceIncident]?).self) { group in
            for source in requestedSources {
                group.addTask {
                    do {
                        var request = URLRequest(url: source.url)
                        request.timeoutInterval = 12
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            return (source, nil)
                        }
                        let incidents = try parse(data, source: source)
                        return (source, incidents)
                    } catch {
                        return (source, nil)
                    }
                }
            }

            var result: [Provider: [ServiceIncident]] = [:]
            for await (source, incidents) in group {
                guard let incidents else { continue }
                for provider in source.providers where providers.contains(provider) {
                    result[provider] = incidents.filter { $0.provider == provider }
                }
            }
            return result
        }
    }

    private static func parse(_ data: Data, source: Source) throws -> [ServiceIncident] {
        switch source.format {
        case .statuspage:
            let page = try JSONDecoder().decode(StatusPageSummary.self, from: data)
            return page.incidents.compactMap { incident in
                guard !["resolved", "completed", "postmortem"].contains(incident.status.lowercased()) else { return nil }
                let componentNames = incident.components.compactMap(\.name)
                let searchable = ([incident.name] + componentNames).joined(separator: " ").lowercased()
                guard source.terms.isEmpty || source.terms.contains(where: { searchable.contains($0) }) else { return nil }
                guard incident.impact.lowercased() != "none" else { return nil }
                let targetURL = URL(string: "\(source.pageURL.absoluteString)/incidents/\(incident.id)") ?? source.pageURL
                return ServiceIncident(
                    provider: source.providers[0], id: incident.id, title: incident.name,
                    status: incident.status, impact: incident.impact, url: targetURL
                )
            }
        case .xaiRSS:
            let feed = RSSIncidentParser.parse(data)
            return feed.compactMap { item in
                let searchText = "\(item.title) \(item.description)".lowercased()
                let title = item.title.lowercased()
                guard source.terms.contains(where: { searchText.contains($0) }),
                      !["resolved", "completed", "operational"].contains(where: { title.contains($0) }),
                      let link = URL(string: item.link), link.scheme == "https" else { return nil }
                let impact = searchText.contains("outage") ? "major" : "minor"
                return ServiceIncident(
                    provider: .grok,
                    id: item.link.isEmpty ? item.title : item.link,
                    title: item.title,
                    status: "active",
                    impact: impact,
                    url: link
                )
            }
        case .googleCloud:
            let records = try JSONDecoder().decode([GoogleCloudIncident].self, from: data)
            return records.flatMap { record -> [ServiceIncident] in
                guard record.end == nil, let impact = record.statusImpact,
                      impact != "SERVICE_HEALTHY", impact != "AVAILABLE" else { return [] }
                let productNames = record.affectedProducts.compactMap(\.title)
                let searchable = ([record.externalDescription, record.serviceName] + productNames)
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                guard source.terms.contains(where: { searchable.contains($0) }) else { return [] }
                return source.providers.map { provider in
                    ServiceIncident(
                        provider: provider, id: record.id,
                        title: record.externalDescription ?? record.serviceName ?? "Google service incident",
                        status: impact.replacingOccurrences(of: "_", with: " ").lowercased(),
                        impact: record.severity ?? "service disruption",
                        url: source.pageURL.appending(path: record.uri ?? "incidents/\(record.id)")
                    )
                }
            }
        }
    }
}

private final class RSSIncidentParser: NSObject, XMLParserDelegate {
    private(set) var items: [(title: String, description: String, link: String)] = []
    private var insideItem = false
    private var currentElement = ""
    private var title = ""
    private var itemDescription = ""
    private var link = ""

    static func parse(_ data: Data) -> [(title: String, description: String, link: String)] {
        let parserDelegate = RSSIncidentParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else { return [] }
        return parserDelegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        if currentElement == "item" || currentElement == "entry" {
            insideItem = true
            title = ""
            itemDescription = ""
            link = attributes["href"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title": title += string
        case "description", "summary", "content:encoded": itemDescription += string
        case "link": if link.isEmpty { link += string }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        if element == "item" || element == "entry" {
            insideItem = false
            items.append((title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          description: itemDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                          link: link.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        currentElement = ""
    }
}

private struct StatusPageSummary: Decodable {
    let incidents: [Incident]
    enum CodingKeys: String, CodingKey { case incidents }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incidents = try container.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
    }
    struct Incident: Decodable {
        let id: String
        let name: String
        let status: String
        let impact: String
        let components: [Component]
        enum CodingKeys: String, CodingKey { case id, name, status, impact, components }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            status = try container.decode(String.self, forKey: .status)
            impact = try container.decodeIfPresent(String.self, forKey: .impact) ?? "minor"
            components = try container.decodeIfPresent([Component].self, forKey: .components) ?? []
        }
    }
    struct Component: Decodable { let name: String? }
}

private struct GoogleCloudIncident: Decodable {
    let id: String
    let end: String?
    let externalDescription: String?
    let statusImpact: String?
    let severity: String?
    let serviceName: String?
    let uri: String?
    let affectedProducts: [Product]

    struct Product: Decodable { let title: String? }

    enum CodingKeys: String, CodingKey {
        case id, end, severity, uri
        case externalDescription = "external_desc"
        case statusImpact = "status_impact"
        case serviceName = "service_name"
        case affectedProducts = "affected_products"
    }
}
