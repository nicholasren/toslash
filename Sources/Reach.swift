import Foundation

/// Loopback, LAN, link-local, and Tailscale (100.64/10) addresses: machines you run.
func isPrivate(_ sa: UnsafeMutablePointer<sockaddr>) -> Bool {
    switch Int32(sa.pointee.sa_family) {
    case AF_INET:
        let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        let (b0, b1) = (a >> 24, (a >> 16) & 0xff)
        return b0 == 10 || b0 == 127 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
            || (b0 == 169 && b1 == 254) || (b0 == 100 && (64...127).contains(b1))
    case AF_INET6:
        let b = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
        let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        return loopback || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
    default:
        return false
    }
}

/// Calls `body` with the resolved addresses, or returns nil if the host does not resolve.
func resolve<T>(_ host: String, _ port: Int, _ body: ([addrinfo]) -> T) -> T? {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0 else { return nil }
    defer { freeaddrinfo(res) }
    var addrs: [addrinfo] = []
    var next = res
    while let ai = next {
        addrs.append(ai.pointee)
        next = ai.pointee.ai_next
    }
    return body(addrs)
}

func connects(_ ai: addrinfo, timeoutMs: Int32) -> Bool {
    let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    if connect(fd, ai.ai_addr, ai.ai_addrlen) == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&p, 1, timeoutMs) == 1 else { return false }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
}

/// nil for public hosts, else whether the port accepts a connection within 0.5s.
/// A host that does not resolve (a home server while you are away) counts as down.
func isUp(_ string: String) -> Bool? {
    guard let url = URL(string: string), let host = url.host else { return nil }
    let up = resolve(host, url.port ?? (url.scheme == "https" ? 443 : 80)) { addrs -> Bool? in
        let mine = addrs.filter { isPrivate($0.ai_addr) }
        return mine.isEmpty ? nil : mine.contains { connects($0, timeoutMs: 500) }
    }
    return up ?? false
}

func statuses(_ urls: [String]) -> [Bool?] {
    var out = [Bool?](repeating: nil, count: urls.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: urls.count) { i in
        let up = isUp(urls[i])
        lock.lock()
        out[i] = up
        lock.unlock()
    }
    return out
}

func resolvesToLoopback(_ host: String) -> Bool {
    resolve(host, 80) { addrs in
        addrs.contains { ai in
            ai.ai_family == AF_INET && ai.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr) == 0x7f00_0001
            }
        }
    } ?? false
}
