import Foundation
import Network

public struct DiscoveredDevice: Sendable, Hashable {
    public let serviceName: String
    public let psn: String

    public var hostname: String { "\(serviceName).local" }
}

/// 在局域网里浏览 `_http._tcp` 服务，找出名字形如 `cp02-<PSN>` 的小电拼。
public enum BonjourScanner {
    public static func scan(duration: TimeInterval = 3) async -> [DiscoveredDevice] {
        await withCheckedContinuation { continuation in
            let box = DiscoveryBox()
            let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                box.add(results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return parse(serviceName: name)
                })
            }
            let queue = DispatchQueue(label: "com.local.CoCanBar.bonjour")
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + duration) {
                browser.cancel()
                continuation.resume(returning: box.sorted())
            }
        }
    }

    public static func parse(serviceName: String) -> DiscoveredDevice? {
        let lower = serviceName.lowercased()
        guard lower.hasPrefix("cp02"), let dash = lower.lastIndex(of: "-") else { return nil }
        let psn = String(lower[lower.index(after: dash)...])
        guard MCPEndpoint.isPSN(psn) else { return nil }
        return DiscoveredDevice(serviceName: lower, psn: psn)
    }
}

final class DiscoveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items = Set<DiscoveredDevice>()

    func add(_ devices: [DiscoveredDevice]) {
        lock.lock()
        items.formUnion(devices)
        lock.unlock()
    }

    func sorted() -> [DiscoveredDevice] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted { $0.psn < $1.psn }
    }
}
