import Darwin
import Foundation

/// One IPv4 address of one network interface, as `getifaddrs` reports it.
struct InterfaceAddress: Equatable {
    var name: String
    var ip: String
}

/// A line of the Network picker.
struct NetworkAddress: Equatable, Identifiable {
    /// What `remote.address` stores: the IP, or the MagicDNS name.
    var value: String
    /// What the picker shows: `192.168.68.51 (en0)`.
    var label: String
    /// The local address the HTTPS listener binds. It differs from `value` only for the MagicDNS name.
    var bindIP: String
    var id: String { value }
}

/// Where the phone connects and what the server binds, worked out from `remote.address` and the current interfaces.
enum RemoteEndpoint: Equatable {
    /// ironpet serves HTTPS on `bindIP`, the phone connects to `host` and pins the certificate.
    case direct(bindIP: String, host: String)
    /// The user's own front (`tailscale serve`, a tunnel) at `url` forwards to the loopback listener. The front has its own certificate.
    case front(url: String)
    /// No usable address: only the loopback listener runs.
    case none

    /// The base URL that goes into the pairing link.
    func baseURL(port: Int) -> String? {
        switch self {
        case .direct(_, let host): return "https://\(host):\(port)"
        case .front(let url): return url
        case .none: return nil
        }
    }

    /// The address the HTTPS listener binds, nil when there is none.
    var bindIP: String? {
        if case .direct(let ip, _) = self { return ip }
        return nil
    }

    /// Whether the link carries the certificate hash. A front presents a certificate of its own, so a pin would fail.
    var pinsCertificate: Bool {
        if case .direct = self { return true }
        return false
    }
}

enum RemoteNetwork {
    /// The IPv4 addresses of every interface that is up and is not loopback or link-local.
    static func interfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            found.append(InterfaceAddress(name: String(cString: entry.ifa_name), ip: ip))
        }
        return found
    }

    /// Tailscale hands out addresses from 100.64.0.0/10 (carrier-grade NAT space).
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in Int(part).map { (0...255).contains($0) && String($0) == part } ?? false }
    }

    /// The picker's lines: Tailscale addresses first, then `en*` (Wi-Fi and Ethernet), then everything else (bridges, other VPNs). Each group
    /// keeps the order the system lists it in. The MagicDNS name, when Tailscale reported one, follows the Tailscale addresses.
    static func addresses(from interfaces: [InterfaceAddress], magicDNS: String? = nil) -> [NetworkAddress] {
        func rank(_ item: InterfaceAddress) -> Int { isTailscale(item.ip) ? 0 : item.name.hasPrefix("en") ? 1 : 2 }
        var seen = Set<String>()
        let ordered = interfaces.filter { seen.insert($0.ip).inserted }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var list = ordered.map { NetworkAddress(value: $0.ip, label: "\($0.ip) (\($0.name))", bindIP: $0.ip) }
        if let name = magicDNS, !name.isEmpty, let tailscale = ordered.first(where: { isTailscale($0.ip) }) {
            let after = ordered.prefix { isTailscale($0.ip) }.count
            list.insert(NetworkAddress(value: name, label: "\(name) (MagicDNS)", bindIP: tailscale.ip), at: after)
        }
        return list
    }

    /// The MagicDNS name from `tailscale status --json` (`Self.DNSName`, which ends in a dot). Nil when it has none.
    static func magicDNSName(statusJSON: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: statusJSON) as? [String: Any],
              let me = root["Self"] as? [String: Any], var name = me["DNSName"] as? String else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// Where the Tailscale command line tool can be. The app's PATH is short, so the usual places are tried.
    static let tailscalePaths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    /// Asks Tailscale for this Mac's MagicDNS name. Nil when Tailscale is missing, stopped or slow (two seconds).
    static func readMagicDNS() async -> String? {
        await Task.detached { () -> String? in
            guard let path = tailscalePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return process.terminationStatus == 0 ? magicDNSName(statusJSON: data) : nil
        }.value
    }

    /// Turns the saved `remote.address` into what the server binds and the link says.
    /// - empty: the first line of the picker
    /// - a line of the picker: that line
    /// - `http://` or `https://`: the user's own front, which forwards to the loopback listener
    /// - an IPv4 address: bind it (never 0.0.0.0 or 127.x), even if the picker does not list it now
    /// - any other text: a host name served by a front, taken as `https://<text>`
    static func endpoint(setting: String, addresses: [NetworkAddress]) -> RemoteEndpoint {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard let first = addresses.first else { return .none }
            return .direct(bindIP: first.bindIP, host: first.value)
        }
        if let line = addresses.first(where: { $0.value == text }) { return .direct(bindIP: line.bindIP, host: line.value) }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            var url = text
            while url.hasSuffix("/") { url.removeLast() }
            return .front(url: url)
        }
        if isIPv4(text) {
            // 0.0.0.0 would listen on every interface, and 127.x is the loopback listener's own address.
            return text == "0.0.0.0" || text.hasPrefix("127.") ? .none : .direct(bindIP: text, host: text)
        }
        return .front(url: "https://\(text)")
    }
}
