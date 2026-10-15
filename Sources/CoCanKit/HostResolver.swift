import Foundation
import Darwin

/// 把设备主机名解析成 IPv4 地址。
///
/// `cp02-<PSN>.local` 如果同时查 A 和 AAAA 记录，实测要等 3–5 秒甚至超时；只查 IPv4 基本是即时返回，
/// 所以先自己解析出 IP，再用 IP 发 HTTP 请求。
public enum HostResolver {
    public static func isIPv4Literal(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    public static func resolveIPv4(_ host: String, timeout: TimeInterval = 3) async -> String? {
        if isIPv4Literal(host) { return host }
        // getaddrinfo 会阻塞且不能取消，所以放到后台线程，并用一次性标记和超时竞争
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            DispatchQueue.global(qos: .utility).async {
                let result = blockingResolve(host)
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    static func blockingResolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        guard first.pointee.ai_family == AF_INET, let sockaddr = first.pointee.ai_addr else { return nil }
        return sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
            var address = sin.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// 只允许第一次 claim 成功，用于保证 continuation 只 resume 一次。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
