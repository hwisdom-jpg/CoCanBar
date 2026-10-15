import SwiftUI
import Charts
import CoCanKit
import CoCanStyle

/// 「调节」页的充电曲线：一个口或各口合计的功率，最近 30 分钟或 2 小时。样式照小程序端口详情页的「历史充电曲线」。
///
/// 最近 30 分钟可以从小电拼内存补上（MCP `get_port_stats`），其余是本 app 运行时用局域网读数记的（见 `PortHistory`）。
/// 鼠标停在曲线上显示那个时刻的读数。
struct ChargingCurve: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig
    let ports: [PortMetrics]
    let configured: Bool
    let online: Bool

    /// nil 是各口合计。
    @State private var selection: Int?
    @State private var choseDefault = false
    @State private var span: Span = Self.demoSpan ?? .halfHour
    @State private var hovered: Date? = Self.demoHover

    enum Span: Hashable, CaseIterable {
        case halfHour, twoHours

        var seconds: TimeInterval { self == .halfHour ? 30 * 60 : 2 * 3600 }
        var title: String { self == .halfHour ? "30 分钟" : "2 小时" }
        /// 横轴每隔几分钟一个刻度。
        var tickMinutes: Int { self == .halfHour ? 10 : 30 }
    }

    private var loading: Bool {
        let busy = model.historyLoading[device.psn] ?? []
        return selection.map { busy.contains($0) } ?? !busy.isEmpty
    }

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-span.seconds)
        let samples = model.historySamples(psn: device.psn, port: selection, since: start, now: now)
        VStack(alignment: .leading, spacing: 10) {
            controls
            chart(samples, start: start, now: now)
                .frame(height: 190)
            if samples.count >= 2 {
                summary(samples)
            }
            if let error = model.historyError[device.psn] {
                Label("读小电拼内存失败：\(error)。先显示本 app 记的。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }
            Text(configured
                 ? "最近 30 分钟从小电拼内存读取（每 10 秒一个点，小电拼断电后清空）；其余是本 app 运行时用局域网读数记的，最多 2 小时，重开 app 后接着显示。"
                 : "没有保存 MCP 地址时，只有本 app 运行时用局域网读数记的，最多 2 小时，重开 app 后接着显示。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: chooseDefault)
        .onChange(of: ports.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
            chooseDefault()
        }
        .task(id: "\(selection.map(String.init) ?? "all")-\(configured)-\(online)-\(choseDefault)") {
            await load(force: false)
        }
    }

    // MARK: 选择端口和时间范围

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("端口", selection: $selection) {
                Text("合计").tag(Int?.none)
                ForEach(ports) { port in
                    Text(PortNaming.name(index: port.id)).tag(Int?.some(port.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            if loading {
                ProgressView()
                    .controlSize(.small)
            } else if configured {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新读小电拼内存里最近 30 分钟的记录")
                .disabled(!online)
            }
            Picker("时间范围", selection: $span) {
                ForEach(Span.allCases, id: \.self) { span in
                    Text(span.title).tag(span)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// 第一次显示时选功率最大的在充口；没有在充的就看合计。
    private func chooseDefault() {
        guard !choseDefault, !ports.isEmpty else { return }
        choseDefault = true
        if let name = Self.demoPort {
            selection = ports.first { PortNaming.name(index: $0.id) == name }?.id
            return
        }
        selection = ports.filter(\.isCharging).max { $0.watts < $1.watts }?.id
    }

    private func load(force: Bool) async {
        // 默认端口选好之前不读，免得刚打开时白读一遍合计
        guard configured, online, choseDefault else { return }
        let ids = selection.map { [$0] } ?? ports.map(\.id)
        await model.loadDeviceHistory(psn: device.psn, ports: ids, force: force)
    }

    // MARK: 曲线

    @ViewBuilder
    private func chart(_ samples: [PowerSample], start: Date, now: Date) -> some View {
        if samples.count < 2 {
            emptyState
        } else {
            let segments = PortHistory.segments(samples)
            let axis = Self.axis(peak: samples.map(\.watts).max() ?? 0)
            let fill = LinearGradient(colors: [Palette.brand.opacity(0.22), Palette.brand.opacity(0.02)],
                                      startPoint: .top, endPoint: .bottom)
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    AreaMark(x: .value("时间", sample.time), y: .value("功率", sample.watts),
                             series: .value("段", segments[index]), stacking: .unstacked)
                        .interpolationMethod(.monotone)
                        .foregroundStyle(fill)
                    LineMark(x: .value("时间", sample.time), y: .value("功率", sample.watts),
                             series: .value("段", segments[index]))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Palette.brand)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
                if let point = Self.nearest(samples, to: hovered) {
                    RuleMark(x: .value("时间", point.time))
                        .foregroundStyle(Palette.brand.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(point)
                        }
                    PointMark(x: .value("时间", point.time), y: .value("功率", point.watts))
                        .foregroundStyle(Palette.brand)
                        .symbolSize(36)
                }
            }
            .chartXScale(domain: start...now)
            .chartYScale(domain: 0...axis.top)
            .chartXSelection(value: $hovered)
            .chartXAxis {
                AxisMarks(values: Self.timeTicks(start: start, end: now, minutes: span.tickMinutes)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Palette.hatch)
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .foregroundStyle(Palette.heading)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: axis.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Palette.hatch)
                    AxisValueLabel {
                        if let watts = value.as(Double.self) {
                            Text(String(format: "%g W", watts))
                                .foregroundStyle(Palette.heading)
                        }
                    }
                }
            }
            // 给悬停读数留一条位置，免得盖住上面的选择器
            .padding(.top, 24)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView()
                    .controlSize(.small)
                Text("正在从小电拼读最近 30 分钟…")
            } else if !online {
                Image(systemName: "wifi.exclamationmark")
                Text("设备离线，暂时没有记录")
            } else {
                Image(systemName: "chart.xyaxis.line")
                Text("还没有记录：本 app 每 10 秒记一个点")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.inset))
    }

    private func tooltip(_ point: PowerSample) -> some View {
        var text = point.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
            + " · " + String(format: "%.2f W", point.watts)
        if selection != nil, point.volts > 0.5 {
            text += " · " + String(format: "%.2f V %.2f A", point.volts, point.amps)
        }
        return Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.brand))
    }

    // MARK: 统计

    private func summary(_ samples: [PowerSample]) -> some View {
        let watts = samples.map(\.watts)
        // 平均只算有功率的时段，没插设备的那段不把数拉低
        let drawing = watts.filter { $0 > 0.05 }
        let average = drawing.isEmpty ? 0 : drawing.reduce(0, +) / Double(drawing.count)
        var items: [(String, String)] = [
            ("平均", String(format: "%.2f W", average)),
            ("峰值", String(format: "%.2f W", watts.max() ?? 0)),
        ]
        if let port = selection.flatMap({ id in ports.first { $0.id == id } }) {
            let volts = samples.map(\.volts).filter { $0 > 0.5 }
            if let low = volts.min(), let high = volts.max() {
                items.append(("电压", String(format: high - low < 0.1 ? "%.2f V" : "%.1f–%.1f V", low, high)))
            }
            if let energy = model.sessionEnergy(device.psn, port: port) {
                items.append(("本次已充", SessionEnergy.format(mWh: energy)))
            }
        } else {
            // 每个点代表 10 秒，按点累加估算这段时间一共充了多少
            let energy = samples.dropLast().map(\.watts).reduce(0, +) * PortHistory.step / 3.6
            items.append(("这段时间约", SessionEnergy.format(mWh: energy)))
        }
        return HStack(spacing: 20) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 计算

    /// 横轴刻度：整 10 分钟（2 小时时整 30 分钟）。离两头太近的不要，标签会被裁掉一半。
    static func timeTicks(start: Date, end: Date, minutes: Int) -> [Date] {
        let step = Double(minutes * 60)
        let margin = end.timeIntervalSince(start) * 0.06
        var tick = (start.timeIntervalSince1970 / step).rounded(.up) * step
        var ticks: [Date] = []
        while tick <= end.timeIntervalSince1970 - margin {
            if tick >= start.timeIntervalSince1970 + margin { ticks.append(Date(timeIntervalSince1970: tick)) }
            tick += step
        }
        return ticks
    }

    static func nearest(_ samples: [PowerSample], to date: Date?) -> PowerSample? {
        guard let date else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    /// 纵轴上限和刻度：取比峰值高一点的整数档，小功率（涓流）也看得清起伏。
    static func axis(peak: Double) -> (top: Double, ticks: [Double]) {
        let steps: [(top: Double, step: Double)] = [
            (1, 0.25), (2, 0.5), (5, 1), (10, 2), (20, 5), (30, 10), (40, 10), (60, 20), (80, 20),
            (100, 25), (120, 30), (160, 40), (200, 50), (240, 60), (300, 100),
        ]
        let choice = steps.first { $0.top >= peak * 1.1 } ?? (top: (peak * 1.1 / 100).rounded(.up) * 100, step: 100)
        let ticks = stride(from: 0, through: choice.top, by: choice.step).map { $0 }
        return (choice.top, ticks)
    }

    #if DEBUG
    /// `--demo-span 2h`：演示时一打开就看 2 小时。
    private static var demoSpan: Span? {
        CommandLine.arguments.contains("--demo-span") && CommandLine.arguments.contains("2h") ? .twoHours : nil
    }

    /// `--demo-hover <分钟>`：演示时当作鼠标停在几分钟前的位置，检查读数气泡。
    private static var demoHover: Date? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-hover"), index + 1 < arguments.count,
              let minutes = Double(arguments[index + 1]) else { return nil }
        return Date().addingTimeInterval(-minutes * 60)
    }

    /// `--demo-curve-port <C1|A|合计…>`：演示时一打开就看这个口，不认识的名字当合计。
    private static var demoPort: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-curve-port"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1].uppercased()
    }
    #else
    private static var demoSpan: Span? { nil }
    private static var demoHover: Date? { nil }
    private static var demoPort: String? { nil }
    #endif
}
