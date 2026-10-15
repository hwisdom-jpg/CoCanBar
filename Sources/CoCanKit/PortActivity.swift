import Foundation

// 端口的芯片温度、本次充电的电量和功率记录（充电曲线）。
//
// 数据来源（2026-10-15 在 CP02 Pro、固件 2.2.0 上实测）：
// - `get_port_details`：每个口的 `die_temperature`（只给档位，不给度数）和 `session_charge_mwh`；
// - `get_port_stats`：小电拼内存里一个口最近的读数，固件每 10 秒存一个平均值，最多 180 个，也就是 30 分钟；
//   点没有时间，最后一个是最新的（隔 46 秒读两次，序列正好左移 4 个点）；
// - 局域网 `metrics.json` 的 `session_charge`：一直在涨的电量计数，单位不是 mWh（见 `SessionEnergy`）。

/// 端口芯片温度的档位（`get_port_details` 的 `die_temperature`）。
/// 实测见过 moderate、warm，cool 出现在 PD 状态里；hot 是按同样的命名推断的，还没见过。
public enum PortTemperature: Sendable, Equatable {
    case cool, moderate, warm, hot
    /// 不认识的档位，原样显示。
    case other(String)

    public init?(_ raw: String?) {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "cool": self = .cool
        case "moderate": self = .moderate
        case "warm": self = .warm
        case "hot": self = .hot
        default: self = .other(text)
        }
    }

    public var label: String {
        switch self {
        case .cool: return "凉爽"
        case .moderate: return "温和"
        case .warm: return "偏热"
        case .hot: return "过热"
        case .other(let text): return text
        }
    }

    /// 设备给的原文，存进小组件快照用。
    public var rawValue: String {
        switch self {
        case .cool: return "cool"
        case .moderate: return "moderate"
        case .warm: return "warm"
        case .hot: return "hot"
        case .other(let text): return text
        }
    }

    /// 0 凉爽 … 3 过热，用来配色；不认识的档位为 nil。
    public var level: Int? {
        switch self {
        case .cool: return 0
        case .moderate: return 1
        case .warm: return 2
        case .hot: return 3
        case .other: return nil
        }
    }
}

/// 一个口的实时详情（`get_port_details`）：芯片温度和本次充电已充的电量。
public struct PortDetail: Sendable, Equatable {
    /// 和 `PortMetrics.id` 一致，从 0 开始。
    public var portID: Int
    public var sessionID: Int?
    /// 本次插入以来充进去的电量（mWh，服务端换算好的）。
    public var sessionEnergyMWh: Int?
    public var temperature: PortTemperature?
    /// 读到这条详情时，局域网读数里同一会话的 `session_charge`。用来把电量往后推算，见 `SessionEnergy`。
    public var lanChargeAtLoad: Int?

    public init(portID: Int, sessionID: Int? = nil, sessionEnergyMWh: Int? = nil,
                temperature: PortTemperature? = nil, lanChargeAtLoad: Int? = nil) {
        self.portID = portID
        self.sessionID = sessionID
        self.sessionEnergyMWh = sessionEnergyMWh
        self.temperature = temperature
        self.lanChargeAtLoad = lanChargeAtLoad
    }

    /// 键是 `PortMetrics.id`。
    public static func parse(_ details: JSONValue?) -> [Int: PortDetail] {
        var result: [Int: PortDetail] = [:]
        for entry in details?["ports"]?.arrayValue ?? [] {
            guard let port = entry["port"]?.looseInt, port >= 1 else { continue }
            result[port - 1] = PortDetail(portID: port - 1,
                                          sessionID: entry["session_id"]?.looseInt,
                                          sessionEnergyMWh: entry["session_charge_mwh"]?.looseInt,
                                          temperature: PortTemperature(entry["die_temperature"]?.stringValue))
        }
        return result
    }
}

/// 本次充电已充的电量。
///
/// 以 MCP 的 `session_charge_mwh` 为准；两次 MCP 读取之间，用局域网 `session_charge` 的增量往后推算，
/// 这样不用频繁问云端，数字也跟着读数每几秒更新。
///
/// 局域网的 `session_charge` 不是 mWh。2026-10-15 在 CP02 Pro（固件 2.2.0）上，四个会话的
/// `session_charge` 和 MCP 的 mWh 之比都在 146,600 左右；拿 5.4 W 的稳定负载按功率积分核对，差约 5%。
/// 开源固件注释里写的 µWs 对不上这个比值。所以比值每次用 MCP 读数现场校准，校准不了才用这个实测值。
public enum SessionEnergy {
    public static let defaultUnitsPerMWh = 146_600.0
    /// 校准结果超出这个范围就不用（固件换了单位之类）。
    static let plausibleUnits = 50_000.0...500_000.0

    /// 用电量最大的会话校准：电量太小时 mWh 的取整误差大，至少要 200 mWh。
    public static func calibrate(_ details: [PortDetail]) -> Double? {
        let best = details
            .compactMap { detail -> (lan: Double, mWh: Double)? in
                guard let mWh = detail.sessionEnergyMWh, mWh >= 200,
                      let lan = detail.lanChargeAtLoad, lan > 0 else { return nil }
                return (Double(lan), Double(mWh))
            }
            .max { $0.mWh < $1.mWh }
        guard let best else { return nil }
        let ratio = best.lan / best.mWh
        return plausibleUnits.contains(ratio) ? ratio : nil
    }

    /// 现在的电量（mWh）：MCP 读数，加上之后局域网计数的增量。读数已经属于另一次插入时返回 nil。
    public static func estimate(_ detail: PortDetail, port: PortMetrics, unitsPerMWh: Double?) -> Double? {
        guard let mWh = detail.sessionEnergyMWh else { return nil }
        if let session = detail.sessionID, let current = port.sessionID, session != current { return nil }
        var value = Double(mWh)
        if let anchor = detail.lanChargeAtLoad, let now = port.sessionCharge, now > anchor {
            value += Double(now - anchor) / (unitsPerMWh ?? defaultUnitsPerMWh)
        }
        return value
    }

    /// 812 mWh、3.46 Wh、40.8 Wh、512 Wh、1.25 kWh。
    public static func format(mWh: Double) -> String {
        switch mWh {
        case ..<999.5: return "\(Int(max(mWh, 0).rounded())) mWh"
        case ..<9_995: return String(format: "%.2f Wh", mWh / 1000)
        case ..<99_950: return String(format: "%.1f Wh", mWh / 1000)
        case ..<999_500: return String(format: "%.0f Wh", mWh / 1000)
        default: return String(format: "%.2f kWh", mWh / 1_000_000)
        }
    }
}

/// 一个口在某个 10 秒里的平均读数。
public struct PowerSample: Sendable, Equatable {
    /// 这 10 秒的开始时刻（对齐到 10 秒）。曲线末尾补的实时读数不对齐。
    public var time: Date
    public var watts: Double
    public var volts: Double
    public var amps: Double

    public init(time: Date, watts: Double, volts: Double, amps: Double) {
        self.time = time
        self.watts = watts
        self.volts = volts
        self.amps = amps
    }
}

extension PowerSample: Codable {
    // 存盘时每个点写成 [时间, W, V, A]，比带键名的对象小一半多。读数保留到 0.01 W、0.001 V、0.001 A。
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        time = Date(timeIntervalSince1970: try container.decode(Double.self))
        watts = try container.decode(Double.self)
        volts = try container.decode(Double.self)
        amps = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(time.timeIntervalSince1970)
        try container.encode((watts * 100).rounded() / 100)
        try container.encode((volts * 1000).rounded() / 1000)
        try container.encode((amps * 1000).rounded() / 1000)
    }
}

/// 一个口的功率记录，画充电曲线用。
///
/// 两个来源：
/// - 本 app 每次读局域网都记一笔，10 秒合成一个点，最多留 2 小时。每分钟存一次盘（见 `HistoryArchive`），重启后还在；
/// - 小电拼内存里的最近 30 分钟（`get_port_stats`，断电清空），能补上 app 启动前、电脑睡眠时的那段。
/// 两边重叠的时段用设备的数据：固件按自己的采样算平均，比几秒读一次局域网准。
public struct PortHistory: Sendable, Equatable, Codable {
    public static let step: TimeInterval = 10
    public static let retention: TimeInterval = 2 * 3600

    /// 本 app 记的点，时间升序。
    public private(set) var recorded: [PowerSample]
    /// 最近一次从设备内存读到的点，时间升序。
    public private(set) var fromDevice: [PowerSample]
    public private(set) var deviceLoadedAt: Date?

    public init(recorded: [PowerSample] = [], fromDevice: [PowerSample] = [], deviceLoadedAt: Date? = nil) {
        self.recorded = recorded
        self.fromDevice = fromDevice
        self.deviceLoadedAt = deviceLoadedAt
    }

    /// 记一个点，丢掉 2 小时以前的。时间不比最后一个点新时忽略。
    public mutating func record(_ sample: PowerSample) {
        if let last = recorded.last, sample.time <= last.time { return }
        recorded.append(sample)
        let cutoff = sample.time.addingTimeInterval(-Self.retention)
        if let first = recorded.first, first.time < cutoff {
            recorded.removeAll { $0.time < cutoff }
        }
    }

    /// 换上新读到的设备数据。旧的设备数据里比新数据早的那段并进本 app 的记录，
    /// 隔了半小时再读、或者重启 app 后再读时，app 启动前那段不会被新数据挤掉。
    public mutating func setDeviceSamples(_ samples: [PowerSample], loadedAt: Date) {
        let sorted = samples.sorted { $0.time < $1.time }
        let cutoff = sorted.first?.time ?? .distantFuture
        recorded = self.samples(since: .distantPast).filter { $0.time < cutoff } + recorded.filter { $0.time >= cutoff }
        fromDevice = sorted
        deviceLoadedAt = loadedAt
    }

    /// 去掉 `cutoff` 以前的点；什么都不剩时返回 nil。设备数据全过期时清掉读取时间，下次显示曲线时重读。
    public func pruned(before cutoff: Date) -> PortHistory? {
        let recorded = recorded.filter { $0.time >= cutoff }
        let fromDevice = fromDevice.filter { $0.time >= cutoff }
        guard !recorded.isEmpty || !fromDevice.isEmpty else { return nil }
        return PortHistory(recorded: recorded, fromDevice: fromDevice, deviceLoadedAt: fromDevice.isEmpty ? nil : deviceLoadedAt)
    }

    /// 合并后的点（时间升序），只取 `start` 之后的：设备数据覆盖的时段用设备的，前后用本 app 记的。
    public func samples(since start: Date) -> [PowerSample] {
        guard let first = fromDevice.first?.time, let last = fromDevice.last?.time else {
            return recorded.filter { $0.time >= start }
        }
        let merged = recorded.filter { $0.time < first } + fromDevice + recorded.filter { $0.time > last }
        return merged.filter { $0.time >= start }
    }

    /// 对齐到 10 秒。
    public static func slot(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    /// `get_port_stats` 的结果换成带时间的点：最后一个点算作 `now` 之前刚结束的那个 10 秒，往前每个点早 10 秒。
    public static func deviceSamples(from value: JSONValue?, now: Date) -> [PowerSample] {
        let entries = value?["samples"]?.arrayValue ?? []
        let end = slot(now).addingTimeInterval(-step)
        return entries.enumerated().map { index, entry in
            let millivolts = entry["voltage_mv"]?.looseDouble ?? 0
            let milliamps = entry["current_ma"]?.looseDouble ?? 0
            let milliwatts = entry["power_mw"]?.looseDouble ?? millivolts * milliamps / 1000
            return PowerSample(time: end.addingTimeInterval(-Double(entries.count - 1 - index) * step),
                               watts: milliwatts / 1000, volts: millivolts / 1000, amps: milliamps / 1000)
        }
    }

    /// 几个口的点按时间相加，得到合计功率（电压、电流相加没有意义，记为 0）。
    public static func total(_ series: [[PowerSample]]) -> [PowerSample] {
        var sums: [Date: Double] = [:]
        for samples in series {
            for sample in samples { sums[sample.time, default: 0] += sample.watts }
        }
        return sums.keys.sorted().map { PowerSample(time: $0, watts: sums[$0] ?? 0, volts: 0, amps: 0) }
    }

    /// 给每个点分段：相邻两点隔得太久（app 没在运行、设备离线）就断开，不连成一条斜线。
    public static func segments(_ samples: [PowerSample], maxGap: TimeInterval = 3 * step) -> [Int] {
        var result: [Int] = []
        var segment = 0
        for (index, sample) in samples.enumerated() {
            if index > 0, sample.time.timeIntervalSince(samples[index - 1].time) > maxGap { segment += 1 }
            result.append(segment)
        }
        return result
    }
}

/// 充电曲线存盘的内容：每台设备每个口的记录。app 每分钟存一次、退出时再存一次，启动时读回 2 小时内的。
public struct HistoryArchive: Codable, Sendable, Equatable {
    public var format = 1
    public var savedAt: Date
    /// 键是 PSN 和 `PortMetrics.id`。
    public var devices: [String: [Int: PortHistory]]

    public init(savedAt: Date, devices: [String: [Int: PortHistory]]) {
        self.savedAt = savedAt
        self.devices = devices
    }

    /// 只留这几台设备、`now` 之前 2 小时内的点（时钟往回拨过时，未来的点也留着，不影响画图）。
    public func pruned(now: Date, keeping psns: Set<String>) -> [String: [Int: PortHistory]] {
        let cutoff = now.addingTimeInterval(-PortHistory.retention)
        var result: [String: [Int: PortHistory]] = [:]
        for (psn, ports) in devices where psns.contains(psn) {
            let kept = ports.compactMapValues { $0.pruned(before: cutoff) }
            if !kept.isEmpty { result[psn] = kept }
        }
        return result
    }

    public static func load(from url: URL) -> HistoryArchive? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(HistoryArchive.self, from: data), archive.format == 1 else { return nil }
        return archive
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// 把一次次局域网读数攒成 10 秒一个点。
public struct HistoryRecorder: Sendable, Equatable {
    private var slot: Date?
    private var watts = 0.0
    private var volts = 0.0
    private var amps = 0.0
    private var count = 0

    public init() {}

    /// 加一笔读数。进入下一个 10 秒时返回上一个 10 秒的平均值。
    public mutating func add(watts: Double, volts: Double, amps: Double, at time: Date) -> PowerSample? {
        let current = PortHistory.slot(time)
        var finished: PowerSample?
        if let slot, slot != current {
            if current > slot, count > 0 {
                let n = Double(count)
                finished = PowerSample(time: slot, watts: self.watts / n, volts: self.volts / n, amps: self.amps / n)
            }
            self.watts = 0
            self.volts = 0
            self.amps = 0
            count = 0
        }
        slot = current
        self.watts += watts
        self.volts += volts
        self.amps += amps
        count += 1
        return finished
    }
}

/// 一次读到的各口信息：接的设备和实时详情（温度、本次电量）。
public struct PortInfo: Sendable, Equatable {
    /// 键都是 `PortMetrics.id`。
    public var identities: [Int: PortIdentity]
    public var details: [Int: PortDetail]

    public init(identities: [Int: PortIdentity] = [:], details: [Int: PortDetail] = [:]) {
        self.identities = identities
        self.details = details
    }
}

public extension MCPClient {
    /// 各口接的设备、芯片温度和本次电量：`get_port_pd_status` 和 `get_port_details` 同时调。
    /// `get_port_details` 读不到不算失败，这时只有识别结果。
    func portInfo() async throws -> PortInfo {
        async let detailsJSON = optionalJSON("get_port_details")
        let pdStatus = try await callToolJSON("get_port_pd_status")
        let details = await detailsJSON
        return PortInfo(identities: PortIdentity.parse(pdStatus: pdStatus, details: details),
                        details: PortDetail.parse(details))
    }

    /// 小电拼内存里这个口最近 30 分钟的读数（`get_port_stats`，只读）。`portID` 是 `PortMetrics.id`。
    func portHistory(portID: Int, now: Date = Date()) async throws -> [PowerSample] {
        let value = try await callToolJSON("get_port_stats", arguments: ["port": .number(Double(portID + 1))])
        return PortHistory.deviceSamples(from: value, now: now)
    }

    private func optionalJSON(_ name: String) async -> JSONValue? {
        try? await callToolJSON(name)
    }
}
