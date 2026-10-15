import Foundation
import CoCanKit

// cocan-probe：不开界面，验证 CoCanKit 的局域网读数和 MCP 调用。
//
//   cocan-probe lan <主机名或 IP>
//   cocan-probe lan-check <PSN> [主机名或 IP]
//   cocan-probe scan
//   cocan-probe mcp <含 MCP 地址的文件> <PSN> [工具名] [JSON 参数] [--allow-write]
//
// mcp 子命令默认只允许 get_ 开头的只读工具；要执行开关、改策略等写操作必须显式加 --allow-write。
// 任何输出都不包含 MCP 地址里的 token。

let usage = """
用法：
  cocan-probe lan <主机名或 IP>
  cocan-probe lan-check <PSN> [主机名或 IP]  （和小组件一样读一次：解析、核对 PSN、读数；输出不带 PSN 和地址）
  cocan-probe scan
  cocan-probe mcp <含 MCP 地址的文件> <PSN> [工具名] [JSON 参数] [--allow-write]
  cocan-probe mcp <含 MCP 地址的文件> <PSN> --schema    （打印每个工具的说明和参数结构）
  cocan-probe mcp <含 MCP 地址的文件> <PSN> --identify  （识别各口接的设备，和 app 用同一套规则）
  cocan-probe mcp <含 MCP 地址的文件> <PSN> --history C1 （小电拼内存里这个口最近 30 分钟的读数）
  cocan-probe mcp <含 MCP 地址的文件> <PSN> --cloud     （和 app 离网时一样读一次云端读数，可以和 lan 的输出对照）
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

/// 端口开关状态：云端读数里没在供电的口不知道开没开。
func powerText(_ port: PortMetrics) -> String {
    port.isPoweredOn.map { "\($0)" } ?? "未知"
}

var args = Array(CommandLine.arguments.dropFirst())
let allowWrite = args.contains("--allow-write")
args.removeAll { $0 == "--allow-write" }

switch args.first {
case "lan":
    guard args.count >= 2 else { fail(usage) }
    let host = args[1]
    let started = Date()
    guard let ip = await HostResolver.resolveIPv4(host) else { fail("解析失败：\(host)") }
    print("解析 \(host) -> \(ip)，用时 \(fixed(Date().timeIntervalSince(started), 2)) 秒")
    let lan = LANClient()
    do {
        let info = try await lan.info(ip: ip)
        print("设备：\(info.deviceName ?? "-") · \(info.productFamily ?? "-") \(info.deviceModel ?? "-") · ESP32 \(info.esp32Version ?? "-") · PSN \(info.psn ?? "-")")
        let metrics = try await lan.metrics(ip: ip)
        print("合计 \(fixed(metrics.totalWatts, 2)) W，充电中 \(metrics.chargingCount) 个口，固件 \(metrics.system?.appVersion ?? "-")")
        for port in metrics.ports {
            let name = PortNaming.name(index: port.id, family: info.productFamily)
            print("  \(name)\t开=\(powerText(port)) 状态=\(port.state) 连接=\(port.attached) "
                  + "\(fixed(port.volts, 2)) V \(fixed(port.amps, 3)) A \(fixed(port.watts, 2)) W "
                  + "\(port.protocolName) \(port.chargingDurationSeconds) s 预算 \(port.powerBudgetWatts) W")
        }
    } catch {
        fail("读取失败：\(error.localizedDescription)")
    }

case "lan-check":
    guard args.count >= 2 else { fail(usage) }
    let psn = args[1]
    let host = args.count >= 3 ? args[2] : "cp02-\(psn).local"
    let started = Date()
    do {
        let metrics = try await LANClient().verifiedMetrics(psn: psn, host: host)
        print("核对通过：合计 \(fixed(metrics.totalWatts, 2)) W，\(metrics.ports.count) 个口，充电中 \(metrics.chargingCount) 个，"
              + "用时 \(fixed(Date().timeIntervalSince(started), 2)) 秒")
    } catch LANError.unresolved {
        fail("读取失败：解析不到主机名")
    } catch LANError.wrongDevice {
        fail("读取失败：地址上是另一台设备")
    } catch {
        fail("读取失败：\(error.localizedDescription)")
    }

case "scan":
    let found = await BonjourScanner.scan(duration: 3)
    print("发现 \(found.count) 台")
    for device in found { print("  \(device.serviceName)  PSN \(device.psn)") }

case "mcp":
    guard args.count >= 3 else { fail(usage) }
    guard let text = try? String(contentsOfFile: (args[1] as NSString).expandingTildeInPath, encoding: .utf8) else {
        fail("读不到文件：\(args[1])")
    }
    guard let endpoint = MCPEndpoint.extractAll(from: text).first(where: { $0.psn == args[2] }) else {
        fail("文件里没有 PSN \(args[2]) 的 MCP 地址")
    }
    print("MCP：\(endpoint.redacted)")
    let client = MCPClient(endpoint: endpoint)
    do {
        if args.count == 3 {
            let tools = try await client.listTools()
            print("工具 \(tools.count) 个：" + tools.map(\.name).joined(separator: ", "))
        } else if args[3] == "--schema" {
            // 每个工具的说明和参数结构（tools/list 只读）；输出前同样脱敏
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            for tool in try await client.listTools() {
                let schema = tool.inputSchema.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                print(endpoint.redact("## \(tool.name)\n\(tool.description)\n\(schema)\n"))
            }
        } else if args[3] == "--identify" {
            // 和 app 一样识别各口接的设备，附带芯片温度和本次电量（get_port_pd_status + get_port_details，都是只读）
            let info = try await client.portInfo()
            if info.identities.isEmpty { print("没有接入设备") }
            for (id, identity) in info.identities.sorted(by: { $0.key < $1.key }) {
                let detail = info.details[id]
                let battery = identity.battery.map { "电量 \($0.percent)% · 健康 \($0.health)% · 设计 \(fixed($0.designWh, 1)) Wh" }
                let cable = identity.usesPD && id != 0 ? "线材 " + (identity.cable?.summary ?? "没有 E-Marker") : nil
                let idLine = identity.idText ?? (identity.recognizedByServer ? nil : "没报厂商号")
                let parts = [identity.displayName ?? "未识别", idLine, identity.pdSummary ?? "不走 PD",
                             battery, cable,
                             detail?.temperature.map { "芯片 \($0.label)" },
                             detail?.sessionEnergyMWh.map { "本次 \(SessionEnergy.format(mWh: Double($0)))" },
                             identity.sessionID.map { "会话 \($0)" }]
                print("  \(PortNaming.name(index: id))\t" + parts.compactMap { $0 }.joined(separator: " · "))
            }
        } else if args[3] == "--cloud" {
            // 和 app 连不上局域网时一样读一次云端（get_port_details，只读）。云端没有开关状态、充电时长和分配功率
            let reading = try await client.cloudReading()
            print("合计 \(fixed(reading.metrics.totalWatts, 2)) W，充电中 \(reading.metrics.chargingCount) 个口（云端读数）")
            for port in reading.metrics.ports {
                let detail = reading.details[port.id]
                let parts = ["开=\(powerText(port)) 连接=\(port.attached)",
                             "\(fixed(port.volts, 2)) V \(fixed(port.amps, 3)) A \(fixed(port.watts, 2)) W \(port.protocolName)",
                             detail?.temperature.map { "芯片 \($0.label)" },
                             detail?.sessionEnergyMWh.map { "本次 \(SessionEnergy.format(mWh: Double($0)))" }]
                print("  \(PortNaming.name(index: port.id))\t" + parts.compactMap { $0 }.joined(separator: " · "))
            }
        } else if args[3] == "--history" {
            // 小电拼内存里一个口最近 30 分钟的读数（get_port_stats，只读）。端口按名字给，比如 C1
            guard args.count >= 5, let index = (0..<5).first(where: { PortNaming.name(index: $0) == args[4].uppercased() }) else {
                fail("用法：cocan-probe mcp <文件> <PSN> --history <A|C1|C2|C3|C4>")
            }
            let samples = try await client.portHistory(portID: index)
            let watts = samples.map(\.watts)
            let format = DateFormatter()
            format.dateFormat = "HH:mm:ss"
            print("\(args[4].uppercased())：\(samples.count) 个点，"
                  + "\(samples.first.map { format.string(from: $0.time) } ?? "-") 到 \(samples.last.map { format.string(from: $0.time) } ?? "-")，"
                  + "平均 \(fixed(watts.reduce(0, +) / Double(max(watts.count, 1)), 2)) W，峰值 \(fixed(watts.max() ?? 0, 2)) W")
            for sample in samples.suffix(6) {
                print("  \(format.string(from: sample.time))  \(fixed(sample.volts, 2)) V  \(fixed(sample.amps, 3)) A  \(fixed(sample.watts, 2)) W")
            }
        } else {
            let tool = args[3]
            guard tool.hasPrefix("get_") || allowWrite else {
                fail("\(tool) 不是只读工具；确实要执行请加 --allow-write")
            }
            var arguments: [String: JSONValue] = [:]
            if args.count >= 5 {
                guard let object = JSONValue.parse(args[4])?.objectValue else { fail("参数必须是 JSON 对象") }
                arguments = object
            }
            print(try await client.callTool(tool, arguments: arguments))
        }
    } catch {
        fail("MCP 调用失败：\(error.localizedDescription)")
    }

default:
    print(usage)
}
