import SwiftUI
import ServiceManagement
import CoCanKit
import CoCanStyle

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ControlsSettings()
                .tabItem { Label("调节", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.controls)
            DevicesSettings()
                .tabItem { Label("设备", systemImage: "bolt.horizontal") }
                .tag(SettingsTab.devices)
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 540, height: 600)
    }
}

/// 设备列表：名称、主机、MCP 地址（存钥匙串）、添加和删除。
struct DevicesSettings: View {
    @Environment(AppModel.self) private var model

    @State private var newURL = ""
    @State private var scanning = false
    @State private var found: [DiscoveredDevice] = []
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        Form {
            ForEach(model.devices) { device in
                Section(device.name) {
                    DeviceEditor(device: device)
                }
            }
            Section("添加设备") {
                SecureField("MCP 地址", text: $newURL, prompt: Text("从小程序「MCP 指南」复制后粘贴"))
                HStack {
                    Button("用 MCP 地址添加") { addFromURL() }
                        .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button(scanning ? "正在扫描…" : "扫描局域网") { scan() }
                        .disabled(scanning)
                }
                ForEach(found, id: \.psn) { candidate in
                    HStack {
                        Text(candidate.serviceName)
                            .font(.callout.monospaced())
                        Spacer()
                        Button("添加") {
                            model.addDevice(psn: candidate.psn, name: nil)
                            found.removeAll { $0.psn == candidate.psn }
                        }
                    }
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(messageIsError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        // 和「调节」页同一个底色，系统的分组卡片放在上面
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
    }

    private func addFromURL() {
        do {
            let endpoint = try model.saveMCP(newURL)
            newURL = ""
            message = "已保存 \(endpoint.redacted)"
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    private func scan() {
        scanning = true
        message = nil
        Task {
            found = await model.scanLAN()
            scanning = false
            message = found.isEmpty ? "没有发现新的小电拼（已添加的不再列出）。如果系统询问“本地网络”权限，请允许。" : nil
            messageIsError = false
        }
    }
}

struct DeviceEditor: View {
    @Environment(AppModel.self) private var model
    let device: DeviceConfig

    private enum Field { case name, host }

    // 名称和主机先编辑草稿，按回车或离开输入框时才写入，避免输到一半就生效
    @State private var nameDraft = ""
    @State private var hostDraft = ""
    @FocusState private var focus: Field?
    @State private var urlDraft = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false
    @State private var confirmDelete = false

    private var configured: Bool { model.mcpConfigured.contains(device.psn) }

    var body: some View {
        TextField("名称", text: $nameDraft)
            .focused($focus, equals: .name)
            .onSubmit(commitName)
            .onAppear {
                nameDraft = device.name
                hostDraft = device.hostOverride ?? ""
            }
            .onChange(of: focus) { previous, _ in
                if previous == .name { commitName() }
                if previous == .host { commitHost() }
            }
            // 没按回车就关掉设置窗口时也保存
            .onDisappear {
                commitName()
                commitHost()
            }
        LabeledContent("PSN") {
            Text(device.psn)
                .monospaced()
                .textSelection(.enabled)
        }
        TextField("主机", text: $hostDraft, prompt: Text(device.defaultHost))
            .focused($focus, equals: .host)
            .onSubmit(commitHost)
        LabeledContent("MCP") {
            Text(configured ? "已保存在钥匙串" : "未配置")
                .foregroundStyle(configured ? .primary : .secondary)
        }
        SecureField(configured ? "替换地址" : "MCP 地址", text: $urlDraft,
                    prompt: Text(configured ? "粘贴新的 MCP 地址" : "从小程序「MCP 指南」复制后粘贴"))
        HStack {
            Button("保存地址") { save() }
                .disabled(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(testing ? "测试中…" : "测试连接") { test() }
                .disabled(!configured || testing)
            Spacer()
            Button("删除设备", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("删除「\(device.name)」？", isPresented: $confirmDelete) {
            Button("删除设备和钥匙串里的 MCP 地址", role: .destructive) { remove() }
        } message: {
            Text("之后要重新粘贴 MCP 地址才能控制这台设备。")
        }
        if let status {
            Text(status)
                .font(.caption)
                .foregroundStyle(statusIsError ? .red : .secondary)
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nameDraft = device.name
        } else if trimmed != device.name {
            model.rename(device.psn, to: trimmed)
        }
    }

    private func commitHost() {
        model.setHost(device.psn, hostDraft)
    }

    private func remove() {
        do {
            try model.removeDevice(device.psn)
        } catch {
            status = "删除失败，设备已保留：\(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func save() {
        do {
            _ = try model.saveMCP(urlDraft, expectedPSN: device.psn)
            urlDraft = ""
            status = "已保存到钥匙串"
            statusIsError = false
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func test() {
        testing = true
        Task {
            switch await model.testMCP(psn: device.psn) {
            case .success(let count):
                status = "连接正常：服务提供 \(count) 个工具"
                statusIsError = false
            case .failure(let error):
                status = error.localizedDescription
                statusIsError = true
            }
            testing = false
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("刷新间隔", selection: $model.pollInterval) {
                Text("2 秒").tag(2.0)
                Text("3 秒").tag(3.0)
                Text("5 秒").tag(5.0)
                Text("10 秒").tag(10.0)
            }
            Toggle("登录时启动", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { enabled in
                    do {
                        try model.setLaunchAtLogin(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    loginStatus = model.launchAtLoginStatus
                }))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("还需要在「系统设置 › 通用 › 登录项」里允许。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Section("说明") {
                Text("读数：局域网 http://<设备>/metrics.json，每隔几秒读一次，不需要登录。")
                Text("控制：官方 MCP（\(MCPEndpoint.host)）。MCP 地址含 token，只保存在登录钥匙串，服务名 \(KeychainStore.defaultService)。")
                Text("MCP 不提供读取当前充电策略，面板上显示的是上次由本 app 设置的值。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .onAppear { loginStatus = model.launchAtLoginStatus }
    }
}
