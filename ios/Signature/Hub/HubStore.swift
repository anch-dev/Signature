import Foundation
import Security

/// Connection to the Signature Hub on your PC, plus its live status.
@MainActor
final class HubStore: ObservableObject {
    @Published private(set) var pairing: HubPairing?
    @Published private(set) var status: HubStatus?
    @Published private(set) var reachable = false
    @Published var lastError: String?
    @Published private(set) var datasets: [DatasetSummary] = []
    @Published private(set) var styles: [RemoteStyle] = []
    @Published private(set) var downloadingStyle: String?

    private var pollTask: Task<Void, Never>?

    init() {
        pairing = Keychain.loadPairing()
    }

    var client: HubClient? { pairing.map(HubClient.init) }
    var isPaired: Bool { pairing != nil }

    /// YuE2 installed on the PC (install-yue2.bat).
    var yue2Ready: Bool { reachable && (status?.yue2?.ready ?? false) }
    var yue2Reason: String { status?.yue2?.reason ?? "Update the Hub on your PC to use YuE2." }

    var canGenerate: Bool {
        guard let s = status, reachable else { return false }
        return s.installed.acestep && s.engine.mode != "training" && !(s.training?.isRunning ?? false)
    }

    // MARK: pairing

    /// signature://pair?url=http%3A%2F%2F192.168.1.20%3A8790&token=...&name=GAMING-PC
    @discardableResult
    func handlePairLink(_ url: URL) -> Bool {
        guard url.scheme == "signature", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value, let base = URL(string: raw),
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return false }
        let name = items.first(where: { $0.name == "name" })?.value ?? base.host ?? "PC"
        Task { await pair(base: base, token: token, name: name) }
        return true
    }

    func pair(base: URL, token: String, name: String? = nil) async {
        lastError = nil
        do {
            let pcName = try await HubClient.ping(base)
            let p = HubPairing(url: base, token: token, name: name ?? pcName)
            // Verify the token before saving it.
            _ = try await HubClient(pairing: p).get("/api/status", as: HubStatus.self)
            pairing = p
            Keychain.savePairing(p)
            await refresh()
            startPolling()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pairManually(address: String, token: String) async {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.contains("://") { a = "http://" + a }
        guard var comps = URLComponents(string: a), comps.host != nil else {
            lastError = "Enter the address shown on the Hub, e.g. 192.168.1.20:8790"
            return
        }
        if comps.port == nil { comps.port = 8790 }
        comps.path = ""
        guard let url = comps.url else { return }
        await pair(base: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func unpair() {
        pollTask?.cancel()
        pairing = nil
        status = nil
        datasets = []
        styles = []
        reachable = false
        Keychain.savePairing(nil)
    }

    // MARK: status

    func startPolling() {
        pollTask?.cancel()
        guard isPaired else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                let fast = self?.status?.training?.isRunning == true || self?.status?.engine.state == "starting"
                try? await Task.sleep(nanoseconds: (fast ? 2 : 5) * 1_000_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel() }

    func refreshStatus() async {
        guard let client else { return }
        do {
            status = try await client.get("/api/status", as: HubStatus.self)
            reachable = true
        } catch HubError.server(let m) where m.contains("token") || m.contains("Pair") {
            reachable = false
            lastError = "The PC rejected this device. Scan the pairing code again."
        } catch {
            reachable = false
        }
    }

    func refresh() async {
        await refreshStatus()
        guard let client, reachable else { return }
        do {
            datasets = try await client.get("/api/datasets", as: [DatasetSummary].self)
            styles = try await client.get("/api/styles", as: [RemoteStyle].self)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setMode(_ mode: String) async {
        guard let client else { return }
        struct Body: Encodable { let mode: String; let make_default: Bool }
        do {
            try await client.callIgnoring("POST", "/api/mode", body: Body(mode: mode, make_default: true))
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: styles

    func downloadStyle(_ style: RemoteStyle, into store: AdapterStore) async -> URL? {
        guard let client else { return nil }
        downloadingStyle = style.name
        defer { downloadingStyle = nil }
        let dest = store.dir.appendingPathComponent("\(style.name).safetensors")
        do {
            try await client.download("/api/styles/\(style.name)/file", to: dest)
            store.refresh()
            return dest
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: training

    func startTraining(dataset: String, kind: String, epochs: Int, rank: Int) async {
        guard let client else { return }
        struct Body: Encodable { let dataset: String; let kind: String; let epochs: Int; let rank: Int }
        do {
            try await client.callIgnoring("POST", "/api/train", body: Body(dataset: dataset, kind: kind, epochs: epochs, rank: rank))
            await refreshStatus()
            startPolling()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelTraining() async {
        try? await client?.callIgnoring("POST", "/api/train/cancel")
        await refreshStatus()
    }

    func studioURL() -> URL? {
        guard let p = pairing, var c = URLComponents(url: p.url, resolvingAgainstBaseURL: false) else { return nil }
        c.port = status?.studio_port ?? 7860
        return c.url
    }
}

// MARK: - Keychain (the pairing token is a password)

enum Keychain {
    private static let account = "hub-pairing"
    private static let service = "com.anchdev.signature"

    static func savePairing(_ p: HubPairing?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let p, let data = try? JSONEncoder().encode(p) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadPairing() -> HubPairing? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(HubPairing.self, from: data)
    }
}
