import Foundation

struct OnlineSubtitleResult: Identifiable, Equatable {
    let fileID: Int
    let fileName: String
    let language: String
    let release: String?

    var id: Int { fileID }
}

enum OpenSubtitlesError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenSubtitles API key in Settings before searching."
        case .invalidResponse: "OpenSubtitles returned an unexpected response."
        case .server(let message): message
        }
    }
}

struct OpenSubtitlesClient {
    private static let baseURL = URL(string: "https://api.opensubtitles.com/api/v1/")!

    func search(query: String, language: String, apiKey: String) async throws -> [OnlineSubtitleResult] {
        guard !apiKey.isEmpty else { throw OpenSubtitlesError.missingAPIKey }
        var components = URLComponents(url: Self.baseURL.appending(path: "subtitles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "languages", value: language),
            URLQueryItem(name: "query", value: query),
        ]
        var request = URLRequest(url: try components.requireURL())
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Nura/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let decoded = try decoder().decode(SearchResponse.self, from: data)
        return decoded.data.flatMap { result in
            result.attributes.files.map {
                OnlineSubtitleResult(
                    fileID: $0.fileID,
                    fileName: $0.fileName,
                    language: result.attributes.language,
                    release: result.attributes.release
                )
            }
        }
    }

    func download(result: OnlineSubtitleResult, apiKey: String) async throws -> URL {
        guard !apiKey.isEmpty else { throw OpenSubtitlesError.missingAPIKey }
        var request = URLRequest(url: Self.baseURL.appending(path: "download"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Nura/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["file_id": result.fileID])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let link = try decoder().decode(DownloadResponse.self, from: data).link
        guard let url = URL(string: link) else { throw OpenSubtitlesError.invalidResponse }

        let (subtitleData, subtitleResponse) = try await URLSession.shared.data(from: url)
        try validate(response: subtitleResponse, data: subtitleData)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nura/OnlineSubtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionName = URL(fileURLWithPath: result.fileName).pathExtension.isEmpty ? "srt" : URL(fileURLWithPath: result.fileName).pathExtension
        let destination = directory.appendingPathComponent("\(result.fileID).\(extensionName)")
        try subtitleData.write(to: destination, options: .atomic)
        return destination
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw OpenSubtitlesError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder().decode(ErrorResponse.self, from: data).message)
                ?? "OpenSubtitles request failed (HTTP \(response.statusCode))."
            throw OpenSubtitlesError.server(message)
        }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private struct SearchResponse: Decodable {
    struct Result: Decodable {
        struct Attributes: Decodable {
            struct File: Decodable {
                let fileID: Int
                let fileName: String
            }

            let language: String
            let release: String?
            let files: [File]
        }

        let attributes: Attributes
    }

    let data: [Result]
}

private struct DownloadResponse: Decodable {
    let link: String
}

private struct ErrorResponse: Decodable {
    let message: String
}

private extension URLComponents {
    func requireURL() throws -> URL {
        guard let url else { throw OpenSubtitlesError.invalidResponse }
        return url
    }
}
