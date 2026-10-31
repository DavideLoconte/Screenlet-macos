import Foundation
import Native
import Network

/// Screenlet over the USB cable (PROTOCOL.md, "The cable"). The tablet is the
/// Mac's USB accessory, with one bulk stream each way carrying what would go
/// over the network. Companion TLS connections enter through a loopback TCP
/// listener, so TLS stays end to end. Display datagrams go straight to the
/// stream, one frame per write.
final class Cable {
    enum Kind: UInt8 { case hello = 0, open, data, close, datagram }
    static let identity = ["Screenlet", "Screenlet", "Screenlet on the Mac", "1",
                           "https://github.com/DavideLoconte/Screenlet-Companion", ""]
    static let chunk = 16384          // bytes per read in either direction, as the app transfers
    static let batch = 48 * 1024      // bytes of datagrams in one USB write, at most
    static let answerWait: TimeInterval = 300  // for the user to allow the accessory the first time
    static let maxFrame = 1 << 20     // bytes; a longer frame means a broken or hostile tablet

    private let accessory: POAccessory
    private let writing = NSLock()
    private var listener: Int32 = -1
    private(set) var endpoint: NWEndpoint!   // where companion links connect
    private var connections: [UInt8: Int32] = [:]
    private let lock = NSLock()
    private var next: UInt8 = 0
    private var running = true
    private var buffer = Data()
    /// Writes to and closes the loopback sockets, in order: a socket closes only
    /// after the writes queued for it, so its number is not reused under them.
    private let out = DispatchQueue(label: "screenlet.cable.out")
    private let pending = DispatchSemaphore(value: 64)  // frames queued on out; more stalls the reads, as backpressure
    /// Display datagrams from the tablet.
    var onDatagram: ((Data) -> Void)?
    var onLost: ((Error) -> Void)?

    /// A tablet on the cable, whatever it shows itself as for now.
    struct Plug: Equatable {
        let key: String
        let name: String
    }

    /// The tablets connected, those in accessory mode too.
    static var plugged: [Plug] { POAccessory.tablets().map { Plug(key: $0["key"] ?? "", name: $0["name"] ?? "") } }

    var key: String { accessory.key }

    /// Switches this tablet (nil: the first) to accessory mode and waits for the app to answer. Blocks.
    init(tablet: String? = nil) throws {
        accessory = try POAccessory(tablet: tablet, identity: Cable.identity)
        do {
            try hello()
            try listen()
        } catch {
            accessory.close()
            throw error
        }
        Thread.detachNewThread { [self] in fromTablet() }
        Thread.detachNewThread { [self] in accept() }
    }

    static func frame(_ kind: Kind, _ connection: UInt8, _ data: Data = Data()) -> Data {
        var out = Data(capacity: 6 + data.count)
        out.append(kind.rawValue)
        out.append(connection)
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    /// Removes and returns the complete frames in buffer. Throws on a frame over maxFrame.
    static func frames(_ buffer: inout Data) throws -> [(Kind, UInt8, Data)] {
        var found: [(Kind, UInt8, Data)] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= 6 {
            let length = Int(buffer[at + 2]) << 24 | Int(buffer[at + 3]) << 16 | Int(buffer[at + 4]) << 8 | Int(buffer[at + 5])
            guard length <= maxFrame else { throw Failure("the tablet sent a frame of \(length) bytes") }
            guard buffer.endIndex - at >= 6 + length else { break }
            if let kind = Kind(rawValue: buffer[at]) {
                found.append((kind, buffer[at + 1], buffer.subdata(in: at + 6 ..< at + 6 + length)))
            }
            at += 6 + length
        }
        buffer.removeSubrange(buffer.startIndex ..< at)
        return found
    }

    private func write(_ data: Data, timeout: TimeInterval = 5) throws {
        try write(NSMutableData(data: data), timeout: timeout)
    }

    private func write(_ data: NSMutableData, timeout: TimeInterval = 5) throws {
        writing.lock()
        defer { writing.unlock() }
        try accessory.write(data, timeout: timeout)
    }

    private func read(timeout: TimeInterval) throws -> [(Kind, UInt8, Data)] {
        let into = NSMutableData(length: Cable.chunk)!
        var error: NSError?
        let n = accessory.read(into, timeout: timeout, error: &error)
        if n < 0 { throw error ?? Failure("the cable went") }
        buffer.append(into.bytes.assumingMemoryBound(to: UInt8.self), count: n)
        return try Cable.frames(&buffer)
    }

    /// Sends HELLO until the app reads it (Android asks the user once) and waits
    /// for the reply. Anything open before is closed on both sides.
    private func hello() throws {
        let deadline = Date().addingTimeInterval(Cable.answerWait)
        while (try? write(Cable.frame(.hello, 0), timeout: 1)) == nil {
            if Date() > deadline { throw Failure("Screenlet did not open on the tablet (allow it there)") }
        }
        while Date() < deadline {
            if try read(timeout: 1).contains(where: { $0.0 == .hello }) {
                log("usb: Screenlet's app answers on the cable")
                return
            }
        }
        throw Failure("Screenlet's app did not answer on the cable")
    }

    private func listen() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && Darwin.listen(listener, 8) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard bound else { throw Failure("no local port for the cable") }
        endpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port))!)
    }

    private func accept() {
        while running {
            let conn = Darwin.accept(listener, nil, nil)
            if conn < 0 { return }
            var one: Int32 = 1
            setsockopt(conn, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            next = next % 255 + 1
            let number = next
            connections[number] = conn
            lock.unlock()
            do {
                try write(Cable.frame(.open, number))
            } catch {
                return lost(error)
            }
            Thread.detachNewThread { [self] in toTablet(number, conn) }
        }
    }

    private func toTablet(_ number: UInt8, _ conn: Int32) {
        var bytes = [UInt8](repeating: 0, count: Cable.chunk)
        while true {
            let n = recv(conn, &bytes, bytes.count, 0)
            if n <= 0 { break }
            do {
                try write(Cable.frame(.data, number, Data(bytes[0 ..< n])))
            } catch {
                lost(error)
                break
            }
        }
        lock.lock()
        let mine = connections[number] == conn
        if mine { connections[number] = nil }
        lock.unlock()
        if mine { try? write(Cable.frame(.close, number)) }
        out.async { Darwin.close(conn) }
    }

    private func fromTablet() {
        while running {
            let frames: [(Kind, UInt8, Data)]
            do {
                frames = try read(timeout: 0.5)
            } catch {
                return lost(error)
            }
            for (kind, number, data) in frames {
                lock.lock()
                let conn = connections[number]
                lock.unlock()
                switch kind {
                case .data:
                    guard let conn else { continue }
                    pending.wait()
                    out.async { [self] in
                        defer { pending.signal() }
                        let sent = data.withUnsafeBytes { raw -> Bool in
                            var at = 0
                            while at < raw.count {
                                let n = Darwin.send(conn, raw.baseAddress! + at, raw.count - at, 0)
                                if n <= 0 { return false }
                                at += n
                            }
                            return true
                        }
                        if !sent { forget(number, conn) }
                    }
                case .close:
                    guard let conn else { continue }
                    lock.lock()
                    connections[number] = nil
                    lock.unlock()
                    out.async { shutdown(conn, SHUT_WR) }  // after the data before it
                case .datagram:
                    onDatagram?(data)
                default:
                    break
                }
            }
        }
    }

    private func forget(_ number: UInt8, _ conn: Int32) {
        lock.lock()
        let mine = connections[number] == conn
        if mine { connections[number] = nil }
        lock.unlock()
        if mine { shutdown(conn, SHUT_RDWR) }  // toTablet's recv ends and closes it
    }

    /// Sends one frame's packets in as few USB writes as the app accepts.
    private let batch = NSMutableData(capacity: Cable.batch)!

    /// From one thread at a time (Streamer's sender): each datagram framed
    /// straight into one buffer kept for it, written as it fills.
    func send(datagrams: [Data]) throws {
        do {
            for datagram in datagrams {
                if batch.length > 0 && batch.length + datagram.count + 6 > Cable.batch {
                    try write(batch)
                    batch.length = 0
                }
                var header: (UInt8, UInt8, UInt32) = (Kind.datagram.rawValue, 0, UInt32(datagram.count).bigEndian)
                batch.append(&header.0, length: 1)
                batch.append(&header.1, length: 1)
                batch.append(&header.2, length: 4)
                datagram.withUnsafeBytes { batch.append($0.baseAddress!, length: $0.count) }
            }
            if batch.length > 0 {
                try write(batch)
                batch.length = 0
            }
        } catch {
            batch.length = 0
            lost(error)
            throw error
        }
    }

    private func lost(_ error: Error) {
        guard running else { return }
        log("usb: the cable's link is lost:", error.localizedDescription)
        close()
        onLost?(error)
    }

    func close() {
        guard running else { return }
        running = false
        lock.lock()
        let all = connections.values
        connections.removeAll()
        lock.unlock()
        all.forEach { shutdown($0, SHUT_RDWR) }  // unblocks out and toTablet, which closes them
        Darwin.close(listener)
        accessory.close()
    }
}
