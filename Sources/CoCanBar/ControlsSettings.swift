import SwiftUI
import CoCanKit
import CoCanStyle

/// 设置窗口的「调节」页：官方 MCP 能设置的项都在这里，排版照小程序（奶油底、灰标题、白卡片）。
/// 端口开关（实时调度）、充电模式、温控、屏幕亮度、端口功率分配；
/// CP02S 另有屏显模式、待机显示、整点报时（设备报了才显示）。面板上的「调节」菜单只放常用的几项。
struct ControlsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.devices.isEmpty {
            ContentUnavailableView {
                Label("还没有设备", systemImage: "powerplug")
            } description: {
                Text("先在「设备」页添加小电拼。")
            } actions: {
                Button("去添加") { model.settingsTab = .devices }
            }
        } else if let device = model.settingsDevice.flatMap(model.device) ?? model.devices.first {
            DeviceControls(device: device)
                .id(device.psn)
        }
    }
}

/// 一台设备的全部调节项。底部固定一条状态栏显示执行中和结果，滚动到哪里都看得到。
struct DeviceControls: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig

    @State private var strategyDraft: ChargingStrategy?
    @State private var confirmStrategy = false
    @State private var pendingOff: PortMetrics?
    /// 刚点过的开关先按新状态显示，读数刷新后回到实际状态。
    @State private var switching: [Int: Bool] = [:]
    @State private var allocation: [Int] = []
    /// 草稿已经按设备的当前分配填过（之后读数刷新不再覆盖用户的修改）。
    @State private var allocationFilled = false
    @State private var confirmAllocation = false

    private var state: DeviceRuntime { model.runtime[device.psn] ?? DeviceRuntime() }
    private var control: ControlState { state.control }
    private var configured: Bool { model.mcpConfigured.contains(device.psn) }
    private var online: Bool { model.isOnline(device.psn) }
    private var canSend: Bool { configured && state.busy == nil }
    private var ports: [PortMetrics] { (state.metrics?.ports ?? []).sorted { $0.id < $1.id } }
    private var facts: MachineFacts { model.facts(device.psn) }
    private var lastStrategy: ChargingStrategy? { device.lastStrategy.flatMap(ChargingStrategy.init(rawValue:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.devices.count > 1 {
                    devicePicker
                }
                if !configured {
                    notice
                }
                group("实时调度", detail: "端口开关") { portsTable }
                group("在充设备", detail: identityStatus) {
                    ConnectedDevices(device: device, ports: ports, configured: configured, online: online)
                }
                group("充电曲线", detail: "每 10 秒一个点") {
                    ChargingCurve(device: device, ports: ports, configured: configured, online: online)
                }
                group("充电模式", detail: lastStrategy.map { "上次由本 app 设置：\($0.title)" }) { strategyGrid }
                group("温控与屏幕") { deviceRows }
                group("端口功率分配（临时）", detail: "合计不超过 \(facts.maxPowerBudget) W") { allocationCard }
                if control.supportsExtendedDisplay {
                    group("屏幕显示（CP02S）") { extendedDisplay }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.automatic)
        .background(Palette.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .task {
            strategyDraft = lastStrategy
            await model.loadControls(psn: device.psn)
        }
        // 这一页开着时和面板一样，每隔几秒问一次要不要重新识别接入的设备
        .task(id: configured) {
            guard configured else { return }
            while !Task.isCancelled {
                await model.loadIdentities(psn: device.psn)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onAppear(perform: fillAllocationIfNeeded)
        .onChange(of: ports.isEmpty) { _, _ in fillAllocationIfNeeded() }
        .onChange(of: facts.portMaxPower.count) { _, _ in fillAllocation() }
        .confirmationDialog("关闭 \(pendingOff.map { PortNaming.name(index: $0.id) } ?? "")？",
                            isPresented: Binding(get: { pendingOff != nil }, set: { if !$0 { pendingOff = nil } })) {
            Button("关闭", role: .destructive) {
                if let port = pendingOff { setPort(port, on: false) }
            }
        } message: {
            Text("这个口正在供电，关闭后会断电。")
        }
        .confirmationDialog("切换到「\(strategyDraft?.title ?? "")」？", isPresented: $confirmStrategy) {
            Button("切换") {
                if let strategy = strategyDraft {
                    Task { await model.setStrategy(psn: device.psn, strategy) }
                }
            }
        } message: {
            Text(strategyDraft?.warning ?? "")
        }
        .confirmationDialog("应用这组临时功率分配？", isPresented: $confirmAllocation) {
            Button("应用") {
                let values = allocation
                Task { await model.setPowerAllocation(psn: device.psn, values) }
            }
        } message: {
            Text("\(allocationSummary)。所有端口会重新握手，正在充电的设备会短暂断开。")
        }
    }

    /// 灰色标题 + 白卡片。
    private func group<Content: View>(_ title: String, detail: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: title, detail: detail)
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground(radius: 14))
        }
    }

    private var devicePicker: some View {
        Picker("设备", selection: Binding(get: { device.psn }, set: { model.settingsDevice = $0 })) {
            ForEach(model.devices) { item in
                Text(item.name).tag(item.psn)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
    }

    private var notice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Palette.brand)
            Text("这台设备还没保存 MCP 地址，下面的调节项都不能用。")
                .font(.callout)
            Spacer(minLength: 8)
            Button("去保存") { model.settingsTab = .devices }
        }
        .padding(14)
        .background(CardBackground(radius: 14))
    }

    // MARK: 实时调度（端口开关）

    private var portsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                ForEach(["充电口", "协议", "电压", "电流", "功率", "温度"], id: \.self) { title in
                    Text(title)
                }
                Text("开关")
                    .gridColumnAlignment(.trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.heading)
            .padding(.bottom, 8)
            Rectangle()
                .fill(Palette.ink.opacity(0.75))
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
            if ports.isEmpty {
                Text(online ? "正在读取端口…" : "设备离线，读不到端口状态")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            }
            ForEach(ports) { port in
                portRow(port)
                if port.id != ports.last?.id {
                    DashedLine()
                        .stroke(Palette.hatch, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private func portRow(_ port: PortMetrics) -> some View {
        let name = PortNaming.name(index: port.id)
        let live = port.isInUse
        return GridRow {
            HStack(spacing: 7) {
                PortGlyph(typeA: port.id == 0, scale: 1.25)
                    .foregroundStyle(port.isCharging ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.ink))
                    .frame(width: 18)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .frame(minWidth: 62, alignment: .leading)
            Text(port.isCharging ? FastChargeProtocol.name(port.fcProtocol) : (port.isPoweredOn ? (port.attached ? "已连接" : "–") : "已关闭"))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(live ? String(format: "%.2fV", port.volts) : "–")
                .frame(minWidth: 50, alignment: .leading)
            Text(live ? String(format: "%.2fA", port.amps) : "–")
                .frame(minWidth: 46, alignment: .leading)
            Text(live ? "\(PanelFormat.watts(port.watts))W" : "–")
                .fontWeight(port.isCharging ? .semibold : .regular)
                .foregroundStyle(port.isCharging ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.secondary))
                .frame(minWidth: 48, alignment: .leading)
            Group {
                if live, let temperature = model.temperature(device.psn, port: port) {
                    TemperatureLabel(temperature: temperature)
                        .help("芯片温度：\(temperature.label)（官方 MCP 只给档位）")
                } else {
                    Text("–")
                }
            }
            .frame(minWidth: 40, alignment: .leading)
            PortSwitch(isOn: switching[port.id] ?? port.isPoweredOn, enabled: canSend && online, name: name, size: 1.2) {
                toggle(port, on: !(switching[port.id] ?? port.isPoweredOn))
            }
            .help(port.isPoweredOn ? "关闭 \(name)" : "打开 \(name)")
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.vertical, 9)
    }

    private func toggle(_ port: PortMetrics, on: Bool) {
        if !on, port.isInUse {
            pendingOff = port
            return
        }
        setPort(port, on: on)
    }

    private func setPort(_ port: PortMetrics, on: Bool) {
        switching[port.id] = on
        Task {
            await model.setPort(psn: device.psn, index: port.id, on: on)
            switching[port.id] = nil
        }
    }

    // MARK: 充电模式

    private var strategyGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ChargingStrategy.allCases) { strategy in
                    StrategyTile(strategy: strategy, marked: lastStrategy == strategy, enabled: canSend) {
                        strategyDraft = strategy
                        confirmStrategy = true
                    }
                }
            }
            Text("MCP 读不到设备当前的模式，带标记的是上次由本 app 设置的；在手机上改过也可以再点一次重新下发。"
                 + "小程序里的「苹果全家桶」「自定义」用的是静态分配表，MCP 不能设置。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 温控和亮度

    private var deviceRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow("温控", detail: control.temperature?.detail) {
                Picker("温控", selection: Binding(
                    get: { control.temperature },
                    set: { mode in
                        guard let mode, mode != control.temperature else { return }
                        Task { await model.setTemperature(psn: device.psn, mode) }
                    })) {
                    ForEach(TemperatureMode.allCases) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
            }
            settingRow("屏幕亮度") {
                Picker("屏幕亮度", selection: Binding(
                    get: { control.display },
                    set: { level in
                        guard let level, level != control.display else { return }
                        Task { await model.setDisplay(psn: device.psn, level) }
                    })) {
                    ForEach(DisplayLevel.allCases) { level in
                        Text(level.rawValue).tag(Optional(level))
                    }
                }
            }
            if control.loadedAt == nil {
                Text(control.loadError.map { "读取当前设置失败：\($0)" } ?? "正在读取当前设置…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(control.loadError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.danger))
            }
        }
        .disabled(!canSend)
    }

    private func settingRow<Control: View>(_ title: String, detail: String? = nil,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control()
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
        }
    }

    // MARK: 端口功率分配

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(facts.portMaxPower.enumerated()), id: \.offset) { index, limit in
                AllocationRow(name: PortNaming.name(index: index),
                              value: allocationBinding(index),
                              limit: limit,
                              current: ports.first { $0.id == index }?.powerBudgetWatts,
                              color: ModeColors.standard.port(index))
            }
            AllocationTotal(total: allocation.reduce(0, +), budget: facts.maxPowerBudget)
                .padding(.top, 2)
            if let problem = facts.problem(with: allocation), allocation.count == facts.portMaxPower.count {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }
            HStack {
                Button("填入当前分配") { fillAllocation() }
                    .disabled(ports.isEmpty)
                Button("全部按策略") { allocation = Array(repeating: 0, count: facts.portMaxPower.count) }
                Spacer()
                Button("应用…") { confirmAllocation = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brand)
                    .disabled(!canSend || !online || facts.problem(with: allocation) != nil)
            }
            .controlSize(.regular)
            Text("每个口填 \(MachineFacts.portMinPower) W 到该口上限，最左边是“按策略”（发 0）。"
                 + "按开源固件的实现，应用时所有口会重新握手；之后插拔设备或开关任一端口，设备会回到策略分配。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func allocationBinding(_ index: Int) -> Binding<Int> {
        Binding(get: { allocation.indices.contains(index) ? allocation[index] : 0 },
                set: { value in
                    guard allocation.indices.contains(index) else { return }
                    allocation[index] = value
                })
    }

    private var allocationSummary: String {
        let parts = allocation.enumerated().map { index, watts in
            "\(PortNaming.name(index: index)) \(watts == 0 ? "按策略" : "\(watts) W")"
        }
        return parts.joined(separator: " · ") + "，合计 \(allocation.reduce(0, +)) W"
    }

    /// 第一次有读数时按当前分配填好草稿；之后读数刷新不覆盖用户的修改。
    private func fillAllocationIfNeeded() {
        guard !allocationFilled else { return }
        fillAllocation()
        allocationFilled = !ports.isEmpty
    }

    private func fillAllocation() {
        allocation = facts.portMaxPower.indices.map { index in
            let budget = ports.first { $0.id == index }?.powerBudgetWatts ?? 0
            return budget < MachineFacts.portMinPower ? 0 : min(budget, facts.portMaxPower[index])
        }
    }

    // MARK: CP02S 显示设置

    private var extendedDisplay: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow("屏显模式") {
                Picker("屏显模式", selection: Binding(
                    get: { control.statusMode },
                    set: { mode in
                        guard let mode, mode != control.statusMode else { return }
                        Task { await model.setStatusDisplayMode(psn: device.psn, mode) }
                    })) {
                    ForEach(StatusDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(Optional(mode))
                    }
                }
            }
            HStack {
                Text("待机显示")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Picker("待机显示", selection: Binding(
                    get: { control.idleDisplay },
                    set: { display in
                        guard let display, display != control.idleDisplay else { return }
                        Task { await model.setIdleDisplay(psn: device.psn, display) }
                    })) {
                    ForEach(IdleDisplay.allCases) { display in
                        Text(display.rawValue).tag(Optional(display))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("整点报时")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Toggle("整点报时", isOn: Binding(
                    get: { control.hourlyChime ?? false },
                    set: { enabled in Task { await model.setHourlyChime(psn: device.psn, enabled) } }))
                    .toggleStyle(.switch)
                    .tint(Palette.brand)
                    .labelsHidden()
            }
        }
        .disabled(!canSend)
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = state.busy {
                ProgressView()
                    .controlSize(.small)
                Text(busy)
            } else if let message = state.message {
                Image(systemName: state.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.messageIsError ? Palette.danger : Palette.online)
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                StatusBadge(status: online ? .online : (state.lastError == nil ? .connecting : .offline))
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                Task {
                    await model.refresh(device.psn)
                    async let controls: Void = model.loadControls(psn: device.psn, force: true)
                    async let identities: Void = model.loadIdentities(psn: device.psn, force: true)
                    _ = await (controls, identities)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新读取端口、当前设置和接入的设备")
            .disabled(!configured || state.busy != nil)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 「在充设备」标题右边的状态。
    private var identityStatus: String? {
        guard configured, online else { return nil }
        let identity = state.identity
        if identity.loading, identity.loadedAt == nil { return "正在识别…" }
        return identity.loadedAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" }
    }

    private var statusText: String {
        guard online else { return state.lastError == nil ? "正在连接 \(device.effectiveHost)…" : "离线" }
        let total = PanelFormat.watts(state.metrics?.totalWatts ?? 0)
        let charging = state.metrics?.chargingCount ?? 0
        return charging > 0 ? "\(device.name) · \(charging) 口在充 · \(total) W" : "\(device.name) · 没有在充"
    }
}

/// 充电模式的一格，照小程序「模式」页：圆角方块里放图标，下面是名称和说明。
/// 上次由本 app 设置的那一格用该模式的主题色描边。
private struct StrategyTile: View {
    let strategy: ChargingStrategy
    let marked: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    private var theme: Color { ModeColors.of(strategy).theme }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(marked ? AnyShapeStyle(theme) : AnyShapeStyle(Palette.card))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(marked ? AnyShapeStyle(theme) : AnyShapeStyle(Palette.pillStroke), lineWidth: 1.2)
                    }
                    .overlay {
                        Image(systemName: strategy.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(marked ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.heading))
                    }
                    .frame(width: 48, height: 48)
                Text(strategy.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(strategy.tileDetail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .top)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering && enabled ? AnyShapeStyle(Palette.columnHover) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .help(marked ? "上次由本 app 设置的模式；点按可重新下发" : "切换到\(strategy.title)")
    }
}

/// 一个口的分配：滑块最左一格是“按策略”（发 0），往右是 15 W 到该口上限，按 1 W 取整。
/// 滑块不设步进：设了步进 macOS 会画出上百条刻度。
private struct AllocationRow: View {
    let name: String
    @Binding var value: Int
    let limit: Int
    let current: Int?
    let color: Color

    private var floor: Int { MachineFacts.portMinPower - 1 }

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 30, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value == 0 ? floor : value) },
                set: { raw in
                    let watts = Int(raw.rounded())
                    value = watts <= floor ? 0 : min(watts, limit)
                }), in: Double(floor)...Double(limit))
                .tint(color)
                .controlSize(.small)
            Text(value == 0 ? "按策略" : "\(value) W")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.ink))
                .frame(width: 52, alignment: .trailing)
            Stepper("\(name) 功率", value: $value, in: 0...limit, step: 5)
                .labelsHidden()
                .onChange(of: value) { oldValue, newValue in
                    // 1–14 W 不合法：往上跳到 15 W；往下先停在 15 W，再往下回到“按策略”
                    guard newValue > 0, newValue < MachineFacts.portMinPower else { return }
                    value = oldValue == 0 || oldValue > MachineFacts.portMinPower ? MachineFacts.portMinPower : 0
                }
            Text(current.map { "当前 \($0) W" } ?? "当前 –")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}

/// 合计和整机上限的对比条，超出时变红。
private struct AllocationTotal: View {
    let total: Int
    let budget: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("合计")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize()
                .frame(width: 30, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(Palette.track)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(total > budget ? Palette.danger : Palette.brand)
                            .frame(width: proxy.size.width * min(Double(total) / Double(max(budget, 1)), 1))
                    }
            }
            .frame(height: 6)
            .animation(.snappy, value: total)
            Text("\(total) / \(budget) W")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(total > budget ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(Palette.ink))
                .frame(width: 92, alignment: .trailing)
        }
    }
}

/// 「在充设备」：每个接了设备的口一行，显示识别出的型号、电量、PD 档位和线材。
/// 结果来自官方 MCP（PD 握手里的厂商号、产品号和电池信息），面板或这一页开着时自动更新。
private struct ConnectedDevices: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig
    let ports: [PortMetrics]
    let configured: Bool
    let online: Bool

    private var attached: [PortMetrics] { ports.filter { $0.attached && $0.isPoweredOn } }
    private var identity: IdentityState { model.runtime[device.psn]?.identity ?? IdentityState() }
    /// 插拔后、重新读到之前，没有结果的口显示“正在识别”而不是“未识别”。
    private var pending: Bool { identity.loading || identity.signature != PortIdentity.signature(of: ports) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !configured {
                placeholder("lock", "保存 MCP 地址后才能识别接入的设备")
            } else if !online {
                placeholder("wifi.exclamationmark", "设备离线，读不到接入的设备")
            } else if attached.isEmpty {
                placeholder("powerplug", "没有接入设备")
            } else {
                if let error = identity.loadError {
                    Label("识别失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .padding(.bottom, 4)
                }
                ForEach(attached) { port in
                    row(port)
                    if port.id != attached.last?.id {
                        DashedLine()
                            .stroke(Palette.hatch, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(height: 1)
                    }
                }
            }
            Text("识别靠设备在 PD 握手里报的厂商号和产品号：型号由官方服务端识别，认不出时只显示厂商；"
                 + "不走 PD 的设备认不出来。电量和线材信息由设备上报，仅供参考。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    private func row(_ port: PortMetrics) -> some View {
        let name = PortNaming.name(index: port.id)
        let info = model.identity(device.psn, port: port)
        return HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 7) {
                PortGlyph(typeA: port.id == 0, scale: 1.25)
                    .foregroundStyle(port.isCharging ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.ink))
                    .frame(width: 18)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: 62, height: 17, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(info))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(info?.displayName == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.ink))
                ForEach(lines(port, info), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if let battery = info?.battery {
                BatteryBadge(percent: battery.percent)
            }
        }
        .padding(.vertical, 10)
    }

    private func title(_ info: PortIdentity?) -> String {
        if let name = info?.displayName { return name }
        return info == nil && pending ? "正在识别…" : "未识别的设备"
    }

    private func lines(_ port: PortMetrics, _ info: PortIdentity?) -> [String] {
        var lines = identityLines(port, info)
        // 本次电量和芯片温度不靠识别，不走 PD 的设备也有
        let energy = model.sessionEnergy(device.psn, port: port).map { "本次已充 " + SessionEnergy.format(mWh: $0) }
        let temperature = model.temperature(device.psn, port: port).map { "芯片温度 " + $0.label }
        let activity = [energy, temperature].compactMap { $0 }
        if !activity.isEmpty { lines.append(activity.joined(separator: " · ")) }
        return lines
    }

    private func identityLines(_ port: PortMetrics, _ info: PortIdentity?) -> [String] {
        guard let info else {
            return port.isCharging && !(15...21).contains(port.fcProtocol)
                ? ["协议：\(FastChargeProtocol.name(port.fcProtocol))，不走 PD，认不出型号"] : []
        }
        var lines: [String] = []
        if let id = info.idText {
            lines.append(id)
        } else if info.recognizedByServer {
            // 服务端认出来时不再给厂商号
        } else if info.usesPD {
            lines.append("设备没在 PD 握手里报厂商号和产品号，认不出型号")
        } else if port.isCharging {
            lines.append("协议：\(FastChargeProtocol.name(port.fcProtocol))，不走 PD，认不出型号")
        } else {
            lines.append("没有在取电，暂时认不出")
        }
        if let battery = info.battery {
            lines.append("电量 \(battery.percent)% · 健康 \(battery.health)% · 设计容量 "
                         + String(format: "%.1f Wh", battery.designWh))
        }
        if let pd = info.pdSummary { lines.append(pd) }
        // A 口没有 E-Marker 这回事
        if info.usesPD, port.id != 0 {
            lines.append("线材：" + (info.cable?.summary ?? "没有 E-Marker，最高 3A"))
        }
        return lines
    }
}

/// 电量胶囊：电池图标加百分比，低于 20% 变红。
private struct BatteryBadge: View {
    let percent: Int

    private var symbol: String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(percent)%")
                .monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(percent < 20 ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(Palette.ink))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Palette.inset))
        .accessibilityLabel("电量 \(percent)%")
    }
}

/// 横向虚线（小程序表格的行分隔）。
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
