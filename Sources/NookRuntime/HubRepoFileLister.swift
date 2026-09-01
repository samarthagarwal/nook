import Foundation

struct HubRepoFileEntry: Sendable {
    let path: String
    let size: Int64
}

enum HubRepoFileLister {
    static func listModelFiles(repoId: String, revision: String) async throws -> [HubRepoFileEntry] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repoId)/tree/\(revision)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        let (data, response) = try await NookHubClient.makeSession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode([HubTreeNode].self, from: data)
        return decoded.compactMap { node in
            guard node.type == "file", let size = node.size, size > 0 else { return nil }
            return HubRepoFileEntry(path: node.path, size: size)
        }
    }

    static func filter(_ entries: [HubRepoFileEntry], matching patterns: [String]) -> [HubRepoFileEntry] {
        guard !patterns.isEmpty else { return entries }
        return entries.filter { entry in
            patterns.contains { glob in
                fnmatch(pattern: glob, path: entry.path)
            }
        }
    }

    private static func fnmatch(pattern: String, path: String) -> Bool {
        if pattern == path { return true }
        if pattern.hasPrefix("*.") {
            return path.hasSuffix(String(pattern.dropFirst(1)))
        }
        return false
    }

    private struct HubTreeNode: Decodable {
        let path: String
        let type: String
        let size: Int64?
    }
}
