import CryptoKit
import Foundation
import Network
import Security

/// The companion protocol (PROTOCOL.md): TLS 1.3 with a self-signed
/// certificate on each side, length-framed JSON messages, and pairing by a
/// six-digit code shown on both screens. The identity and paired tablets
/// are kept in ~/Library/Application Support/Screenlet.
enum Companion {
    static let protocolVersion = 1
    static let appPort: UInt16 = 47237
    static let connectTimeout = 5
    static let pairingTimeout: TimeInterval = 120
    static let ioTimeout: TimeInterval = 30
    static let handshakeFor: TimeInterval = 20
    static let linkTimeout = 20       // seconds a session's link waits for the tablet to answer
    static let unpairedHeader = 4096
    static let maxHeader = 64 * 1024
    static let maxName = 64

    static let config = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Screenlet")

    static func sha256(_ parts: Data...) -> Data {
        var hash = SHA256()
        parts.forEach { hash.update(data: $0) }
        return Data(hash.finalize())
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var out = Data(capacity: text.count / 2)
        var at = text.startIndex
        while at < text.endIndex {
            let next = text.index(at, offsetBy: 2)
            guard let byte = UInt8(text[at..<next], radix: 16) else { return nil }
            out.append(byte)
            at = next
        }
        return out
    }

    /// The six-digit code from both certificates (DER, in either order) and both
    /// nonces. The Android app computes the same.
    static func pairingCode(_ a: Data, _ b: Data, ours: Data, theirs: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = sha256(first, second, ours, theirs)
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }

    /// The app's commitment to its nonce, sent before it sees the computer's.
    static func commitment(nonce: Data, appCert: Data, pcCert: Data) -> String {
        hex(sha256(nonce, appCert, pcCert))
    }

    static func fingerprint(_ der: Data) -> String { hex(sha256(der)) }
}

/// This Mac's certificate and key, created with openssl on first use (EC P-256,
/// self-signed) and handed to TLS as an in-memory identity.
final class Identity {
    let certificate: Data     // DER
    let identity: SecIdentity

    static let shared: Result<Identity, Error> = Result { try Identity() }

    private init() throws {
        let dir = Companion.config
        let cert = dir.appendingPathComponent("cert.pem"), key = dir.appendingPathComponent("key.pem")
        let fm = FileManager.default
        if !(fm.fileExists(atPath: cert.path) && fm.fileExists(atPath: key.path)) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Identity.openssl(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                                  "-keyout", key.path + ".part", "-out", cert.path + ".part", "-days", "10950",
                                  "-subj", "/CN=Screenlet on \(Host.current().localizedName ?? "a Mac")"])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path + ".part")
            _ = try fm.replaceItemAt(key, withItemAt: URL(fileURLWithPath: key.path + ".part"))
            _ = try fm.replaceItemAt(cert, withItemAt: URL(fileURLWithPath: cert.path + ".part"))
        }
        let pem = try String(contentsOf: cert, encoding: .utf8)
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw Failure("cert.pem is not a certificate") }
        certificate = der
        // Security only imports a key with its certificate as PKCS#12, so build
        // one in memory and import it without touching the keychain.
        let p12 = try Identity.openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                                        "-passout", "pass:screenlet"])
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "screenlet",
                                                     kSecImportToMemoryOnly: true] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw Failure("this Mac's identity could not be read (\(status))")
        }
        identity = found as! SecIdentity
    }

    @discardableResult
    private static func openssl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("openssl \(arguments[0]) failed") }
        return data
    }
}

/// The paired tablets, stored in paired.json as {fingerprint: {"name": ...}}.
/// Unknown fields are preserved.
enum Paired {
    static let url = Companion.config.appendingPathComponent("paired.json")
    private static let lock = NSLock()

    static func entries() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (fp, entry) in json {
            if let name = entry as? String {
                out[fp] = ["name": name]  // older files store just the name
            } else if let entry = entry as? [String: Any], entry["name"] is String {
                out[fp] = entry
            }
        }
        return out
    }

    /// {fingerprint: name}.
    static func all() -> [String: String] { entries().compactMapValues { $0["name"] as? String } }

    static func add(_ fp: String, name: String, p2p: [String: Any]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var data = entries()
        data[fp, default: [:]]["name"] = name
        if let p2p { data[fp]!["p2p"] = p2p }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            FileManager.default.createFile(atPath: url.path, contents: json, attributes: [.posixPermissions: 0o600])
        }
    }
}

/// A TLS link to the app carrying framed messages (a 4-byte big-endian length
/// and a JSON header). Its calls block, so use it from its own thread.
final class Link {
    let connection: NWConnection
    private(set) var peerCertificate: Data?
    private let queue = DispatchQueue(label: "screenlet.link")

    struct Closed: LocalizedError {
        var errorDescription: String? { "the tablet closed the connection" }
    }

    init(to endpoint: NWEndpoint) throws {
        let me = try Identity.shared.get()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, sec_identity_create(me.identity)!)
        var peer: Data?
        // No CA signs either certificate. The app's is checked against the
        // paired list, or the user compares the pairing code.
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            peer = chain?.first.map { SecCertificateCopyData($0) as Data }
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // send small messages immediately
        tcp.connectionTimeout = Companion.connectTimeout
        // A tablet that leaves the network sends nothing, not even a reset, so
        // give up after this instead of waiting for TCP's 15-minute timeout.
        tcp.connectionDropTime = Companion.linkTimeout
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // IPv4, because the display's packets go to the address this link reached.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        connection = NWConnection(to: endpoint, using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e), .waiting(let e): failure = e; ready.signal()
            case .cancelled: failure = failure ?? Closed(); ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + .seconds(Companion.connectTimeout + 5)) == .timedOut {
            connection.cancel()
            throw Failure("the tablet did not answer")
        }
        connection.stateUpdateHandler = nil
        if let failure {
            connection.cancel()
            throw failure
        }
        peerCertificate = queue.sync { peer }
    }

    /// The app's address on this link, where the display's packets go.
    var remoteHost: String? {
        if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint {
            switch host {
            case .ipv4(let a): return "\(a)".components(separatedBy: "%")[0]
            case .ipv6(let a): return "\(a)".components(separatedBy: "%")[0]
            case .name(let n, _): return n
            @unknown default: return nil
            }
        }
        return nil
    }

    func send(_ header: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: header)
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(body.count).bigEndian, as: UInt32.self) }
        frame.append(body)
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.send(content: frame, completion: .contentProcessed { failure = $0; done.signal() })
        if done.wait(timeout: .now() + Companion.ioTimeout) == .timedOut { throw Failure("the tablet stopped reading") }
        if let failure { throw failure }
    }

    private func exactly(_ n: Int, timeout: TimeInterval) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(Closed())
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, complete, error in
            if let data, data.count == n {
                result = .success(data)
            } else if let error {
                result = .failure(error)
            } else if complete {
                result = .failure(Closed())
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()  // a pending receive cannot be cancelled, so close the link
            throw Failure("the tablet did not answer in time")
        }
        return try result.get()
    }

    /// Reads the next message, up to limit bytes.
    func receive(limit: Int = Companion.maxHeader, timeout: TimeInterval = Companion.ioTimeout) throws -> [String: Any] {
        let length = try exactly(4, timeout: timeout).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= limit else { throw Failure("bad header length \(length)") }
        let body = try exactly(Int(length), timeout: timeout)
        guard let header = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Failure("a message that is not an object")
        }
        if let size = header["size"] as? Int, size != 0 { throw Failure("the app sends no payloads") }
        return header
    }

    /// Delivers the next message to done on the link's queue, with no timeout.
    func receiveNext(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [connection] data, _, _, error in
            guard let data, data.count == 4 else { return done(.failure(error ?? Closed())) }
            let length = Int(data.big(UInt32.self, at: 0))
            guard length > 0, length <= Companion.maxHeader else { return done(.failure(Failure("bad header length \(length)"))) }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length,
                      let header = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                    return done(.failure(error ?? Closed()))
                }
                done(.success(header))
            }
        }
    }

    func close() { connection.cancel() }
}

struct PairingRefused: LocalizedError {
    let name: String
    var errorDescription: String? { "\(name) is not paired" }
}

struct Impostor: LocalizedError {
    let errorDescription: String?
}

struct Incompatible: LocalizedError {
    let errorDescription: String?
}

struct Refused: LocalizedError {
    let reason: String
    var errorDescription: String? { "the tablet refused: \(reason)" }
}

extension Companion {
    /// Opens a paired link to the app at endpoint and returns the link, the
    /// tablet's name and its fingerprint. Pass ask(name, code) to pair with a new
    /// tablet; without it an unpaired tablet throws PairingRefused. expect is the
    /// id the app announced, and a paired tablet must then present its certificate.
    static func handshake(_ endpoint: NWEndpoint, expect: String? = nil,
                          ask: ((String, String) -> Bool)? = nil) throws -> (Link, String, String) {
        let ours = try Identity.shared.get().certificate
        let link = try Link(to: endpoint)
        do {
            guard let theirs = link.peerCertificate else { throw Failure("the tablet showed no certificate") }
            let fp = fingerprint(theirs)
            let paired = Paired.all()
            let pinned = paired.keys.filter { fp in expect.map { !$0.isEmpty && fp.hasPrefix($0) } ?? false }
            if !pinned.isEmpty && !pinned.contains(fp) {
                throw Impostor(errorDescription: "an app announced as a paired tablet, with another certificate")
            }
            let known = paired[fp] != nil
            try link.send(["type": "hello", "name": Host.current().localizedName ?? "Mac", "version": protocolVersion,
                           "paired": known, "pair": ask != nil])
            let deadline = Date().addingTimeInterval(handshakeFor)
            func small() throws -> [String: Any] {
                try link.receive(limit: unpairedHeader, timeout: max(0.1, deadline.timeIntervalSinceNow))
            }
            let hello = try small()
            let name = String(((hello["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tablet").prefix(maxName))
            if hello["version"] as? Int != protocolVersion {
                throw Incompatible(errorDescription: "\(name) speaks version \(hello["version"] ?? "?"), this Mac \(protocolVersion)")
            }
            if !known || hello["paired"] as? Bool != true {
                guard let ask else { throw PairingRefused(name: name) }
                // The app commits to its nonce, receives ours, then reveals its own.
                let commit = try small()
                var nonce = Data(count: 16)
                guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
                    throw Failure("no random numbers for pairing")
                }
                try link.send(["type": "pair-nonce", "nonce": hex(nonce)])
                let reveal = try small()
                guard let theirNonce = unhex(reveal["nonce"] as? String ?? ""), theirNonce.count == 16,
                      commit["type"] as? String == "pair-commit",
                      commit["commit"] as? String == commitment(nonce: theirNonce, appCert: theirs, pcCert: ours) else {
                    throw PairingRefused(name: name)
                }
                let code = pairingCode(ours, theirs, ours: nonce, theirs: theirNonce)
                log("companion: pairing with \(name), code \(code)")
                let accepted = ask(name, code)
                try link.send(["type": accepted ? "pair-ok" : "pair-no"])
                let answer = try link.receive(limit: unpairedHeader, timeout: pairingTimeout + 10)
                guard accepted, answer["type"] as? String == "pair-ok" else { throw PairingRefused(name: name) }
                Paired.add(fp, name: name)
            } else if let p2p = hello["p2p"] as? [String: Any] {
                // The tablet's own Wi-Fi Direct group, for when there is no network to share.
                Paired.add(fp, name: name, p2p: p2p)
            }
            return (link, name, fp)
        } catch {
            link.close()
            throw error
        }
    }

    /// The first endpoint that answers correctly.
    static func connect(_ endpoints: [NWEndpoint], expect: String?,
                        ask: ((String, String) -> Bool)? = nil) throws -> (Link, String, String) {
        var last: Error = Failure("no address for the tablet")
        for endpoint in endpoints {
            do {
                return try handshake(endpoint, expect: expect, ask: ask)
            } catch let e as PairingRefused {
                throw e
            } catch let e as Incompatible {
                throw e
            } catch {
                log("companion: \(endpoint): \(error.localizedDescription)")
                last = error
            }
        }
        throw last
    }

    /// Pairs with the app at endpoints and returns its fingerprint and name. Blocks.
    static func pair(_ endpoints: [NWEndpoint], ask: @escaping (String, String) -> Bool) throws -> (String, String) {
        let (link, name, fp) = try connect(endpoints, expect: nil, ask: ask)
        try? link.send(["type": "bye"])
        link.close()
        return (fp, name)
    }
}
