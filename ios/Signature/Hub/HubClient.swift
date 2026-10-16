import Foundation

// MARK: - Wire types (match pc/hub/signature_hub/main.py)

struct HubPairing: Codable, Equatable {
    var url: URL
    var token: String
    var name: String
}

struct HubStatus: Decodable {
    struct Engine: Decodable { var mode: String; var state: String; var error: String?; var uptime: Int }
    struct GPU: Decodable { var name: String; var mem_used_mb: Int; var mem_total_mb: Int; var util: Int; var temp_c: Int }
    struct Installed: Decodable { var acestep: Bool; var sidestep: Bool }
    var version: String
    var name: String
    var installed: Installed
    var engine: Engine
    var default_mode: String
    var studio_port: Int
    var gpu: GPU?
    var training: TrainJob?
    var queue: Int
    var loaded_style: String?
}

struct RemoteJob: Decodable, Identifiable {
    struct Meta: Decodable { var bpm: Int?; var key: String?; var duration: Double?; var seed: Int64?; var lyrics: String? }
    var id: String
    var caption: String
    var lyrics: String
    var duration: Double
    var adapter: String?
    var status: String
    var message: String
    var elapsed: Int
    var has_audio: Bool
    var meta: Meta?
}

struct TrainJob: Decodable {
    var kind: String
    var dataset: String
    var epochs: Int
    var rank: Int
    var status: String
    var step: Int
    var steps: [String]
    var step_name: String
    var epoch: Int
    var epochs_total: Int
    var loss: Double?
    var losses: [Double]
    var percent: Int?
    var message: String
    var elapsed: Int

    var isRunning: Bool { status == "running" }

    /// 0...1 across all steps; the train step uses epochs.
    var overall: Double {
        guard !steps.isEmpty else { return 0 }
        var inner = Double(percent ?? 0) / 100
        if step_name == "Train", epochs_total > 0 { inner = Double(epoch) / Double(epochs_total) }
        if status == "done" { return 1 }
        return min(1, (Double(step) + inner) / Double(steps.count))
    }
}

struct DatasetSummary: Decodable, Identifiable, Hashable {
    var name: String
    var style: String
    var songs: Int
    var vocals: Int
    var instrumentals: Int
    var labeled: Int
    var bytes: Int64
    var trained: Bool
    var id: String { name }
}

struct DatasetSong: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var bytes: Int64
    var labeled: Bool
    var caption: String
    var lyrics: String
    var is_instrumental: Bool
    var bpm: String
    var key: String
}

struct DatasetDetail: Decodable {
    var name: String
    var style: String
    var songs: Int
    var labeled: Int
    var trained: Bool
    var items: [DatasetSong]
}

struct RemoteStyle: Decodable, Identifiable, Hashable {
    var name: String
    var bytes: Int64
    var trained_at: Double
    var epochs: Int?
    var songs: Int?
    var final_loss: Double?
    var pc_ready: Bool
    var id: String { name }
}

enum HubError: LocalizedError {
    case notPaired
    case server(String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Pair with your PC first (PC tab)."
        case .server(let m): return m
        case .unreachable(let m): return "Can't reach the PC: \(m)"
        }
    }
}

// MARK: - Client

struct HubClient {
    let pairing: HubPairing

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60 * 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, method: String = "GET", json: Encodable? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: pairing.url) else { throw HubError.server("bad URL") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(AnyEncodable(json))
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: r)
        } catch {
            throw HubError.unreachable(error.localizedDescription)
        }
        try Self.check(data, resp)
        return data
    }

    private static func check(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] as? String {
                throw HubError.server(detail)
            }
            throw HubError.server("PC returned HTTP \(http.statusCode)")
        }
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path)))
    }

    @discardableResult
    func call<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path, method: method, json: body)))
    }

    func callIgnoring(_ method: String, _ path: String, body: Encodable? = nil) async throws {
        _ = try await send(try request(path, method: method, json: body))
    }

    /// Streams a file to disk (song audio or a style .safetensors).
    func download(_ path: String, to dest: URL) async throws {
        let (tmp, resp) = try await Self.session.download(for: try request(path))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try Self.check(data, resp)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Multipart upload of one audio file into a dataset.
    func upload(song file: URL, dataset: String, kind: String) async throws {
        let boundary = "sig-\(UUID().uuidString)"
        var r = try request("/api/datasets/\(dataset)/songs", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 60 * 10

        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let h = try FileHandle(forWritingTo: body)
        func w(_ s: String) { h.write(s.data(using: .utf8)!) }
        w("--\(boundary)\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\n\(kind)\r\n")
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        w("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\n")
        w("Content-Type: application/octet-stream\r\n\r\n")
        let src = try FileHandle(forReadingFrom: file)
        while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty { h.write(chunk) }
        try src.close()
        w("\r\n--\(boundary)--\r\n")
        try h.close()

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await Self.session.upload(for: r, fromFile: body)
        } catch {
            throw HubError.unreachable(error.localizedDescription)
        }
        try Self.check(data, resp)
    }

    /// Unauthenticated check used while pairing.
    static func ping(_ base: URL) async throws -> String {
        var r = URLRequest(url: base.appendingPathComponent("api/ping"))
        r.timeoutInterval = 6
        let (data, _) = try await session.data(for: r)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard obj?["app"] as? String == "signature-hub" else { throw HubError.server("That address isn't a Signature Hub") }
        return obj?["name"] as? String ?? "PC"
    }
}

struct Empty: Decodable {}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
