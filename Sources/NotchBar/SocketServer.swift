import Darwin
import Foundation

/// Unix-domain socket server receiving newline-delimited JSON from `notchbar-hook`.
/// All socket work happens on a private serial queue; callbacks hop to main.
final class SocketServer {
    typealias ClientID = UInt64

    static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/NotchBar/nb.sock"
    }

    /// (event JSON, client id if the hook is waiting for a reply)
    var onMessage: (([String: Any], ClientID?) -> Void)?
    /// A waiting client went away (hook timed out or Claude killed it).
    var onDisconnect: ((ClientID) -> Void)?

    private let queue = DispatchQueue(label: "notchbar.socket")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]
    private var nextID: ClientID = 1
    private let maxMessageBytes = 8 * 1024 * 1024

    private final class Client {
        let id: ClientID
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var awaiting = false
        var gotMessage = false
        init(id: ClientID, fd: Int32) { self.id = id; self.fd = fd }
    }

    func start() throws {
        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); throw posixError("path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else { close(fd); throw posixError("bind") }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { close(fd); throw posixError("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { close(fd) }
        src.resume()
        listenSource = src
    }

    func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for c in clients.values { c.source?.cancel() }
            clients.removeAll()
        }
        unlink(Self.socketPath)
    }

    /// Send a decision to a waiting hook and close the connection.
    func reply(to id: ClientID, _ json: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let client = self.clients[id] else { return }
            if var data = try? JSONSerialization.data(withJSONObject: json) {
                data.append(0x0A)
                _ = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    var off = 0
                    while off < raw.count {
                        let n = write(client.fd, base + off, raw.count - off)
                        if n > 0 { off += n; continue }
                        if n < 0 && errno == EAGAIN { usleep(1000); continue }
                        return false
                    }
                    return true
                }
            }
            client.awaiting = false
            self.drop(client)
        }
    }

    // MARK: private

    private func acceptAll() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let client = Client(id: nextID, fd: cfd)
            nextID += 1
            clients[client.id] = client

            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
            src.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.readFrom(client)
            }
            src.setCancelHandler { close(cfd) }
            client.source = src
            src.resume()
        }
    }

    private func readFrom(_ client: Client) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client.fd, &buf, buf.count)
            if n > 0 {
                guard !client.gotMessage else { continue } // ignore anything after the first line
                client.buffer.append(buf, count: n)
                if client.buffer.count > maxMessageBytes { drop(client); return }
                if let nl = client.buffer.firstIndex(of: 0x0A) {
                    let line = client.buffer[client.buffer.startIndex..<nl]
                    client.gotMessage = true
                    client.buffer = Data()
                    handle(line: Data(line), client: client)
                }
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            // EOF or error
            if client.awaiting {
                let id = client.id
                DispatchQueue.main.async { [weak self] in self?.onDisconnect?(id) }
            }
            drop(client)
            return
        }
    }

    private func handle(line: Data, client: Client) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            drop(client); return
        }
        let awaiting = (json["_await"] as? Bool) == true
        client.awaiting = awaiting
        let id: ClientID? = awaiting ? client.id : nil
        DispatchQueue.main.async { [weak self] in self?.onMessage?(json, id) }
        if !awaiting { drop(client) }
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.source?.cancel()
        client.source = nil
    }

    private func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
