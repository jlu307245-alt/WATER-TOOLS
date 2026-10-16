//
//  QzxyCrypto.swift
//  趣智校园 · 蓝牙水表计费篡改（iOS 版）
//
//  MD5 + AES-128-ECB(NoPadding) —— 对应 Android 端 KlcxkjSigner / KlcxkjCrypto。
//  iOS 的 CryptoKit 不支持 MD5 与 AES-ECB，故直接用 CommonCrypto 的
//  CCCryptorCreateWithMode + ccNoPadding（唯一能关掉 PKCS7 的正确姿势）。
//
import Foundation
import CommonCrypto

enum QzxyCrypto {

    // ══════════════════════════════════════════════════
    //  MD5（签名算法的基础）
    // ══════════════════════════════════════════════════
    static func md5Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // ══════════════════════════════════════════════════
    //  AES-128-ECB 解密（NoPadding，手动去填充）
    //  对应服务端 clData → 0x86 写回字节
    // ══════════════════════════════════════════════════
    static func aesECBDecrypt(_ cipher: Data, key: Data) -> Data? {
        guard !cipher.isEmpty, cipher.count % 16 == 0 else { return nil }

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            CCCryptorCreateWithMode(
                CCOperation(kCCDecrypt),
                CCMode(kCCModeECB),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),     // ★ 关掉 PKCS7，与原实现一致
                nil,
                keyPtr.baseAddress, key.count,
                nil, 0, 0, 0,
                &cryptor
            )
        }
        guard createStatus == kCCSuccess, let c = cryptor else { return nil }
        defer { CCCryptorRelease(c) }

        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            cipher.withUnsafeBytes { inPtr in
                CCCryptorUpdate(c,
                                inPtr.baseAddress, cipher.count,
                                outPtr.baseAddress, out.count,
                                &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    /// Base64 解码（宽松：遇 '=' 或非法字符即停，对齐 native 实现）
    static func base64Decode(_ s: String) -> Data? {
        var cleaned = ""
        for ch in s {
            if ch == "=" { break }
            if ch.isLetter || ch.isNumber || ch == "+" || ch == "/" {
                cleaned.append(ch)
            } else {
                break
            }
        }
        switch cleaned.count % 4 {
        case 2: cleaned += "=="
        case 3: cleaned += "="
        default: break
        }
        return Data(base64Encoded: cleaned)
    }

    /// 去填充 + C 字符串截断（对齐 Android 端 stripPaddingToText）
    static func stripPadding(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        var effective = data
        let last = Int(data[data.count - 1])
        if last >= 1 && last <= data.count {
            let start = data.count - last
            var ok = true
            for i in stride(from: data.count - 1, through: start, by: -1)
            where Int(data[i]) != last { ok = false; break }
            if ok { effective = data.subdata(in: 0..<(data.count - last)) }
            else { return "" }
        }
        if let z = effective.firstIndex(of: 0) {
            effective = effective.subdata(in: 0..<z)
        }
        return String(data: effective, encoding: .utf8)
    }

    // ══════════════════════════════════════════════════
    //  结算回执：clData → 0x86 写回字节
    // ══════════════════════════════════════════════════
    static let aesKey = Data("20210118klcx@002".utf8)

    /// 返回 (明文, 0x86 写回 hex) —— 明文格式 `<前缀>-<dataHex>`
    static func clDataToWriteBack(_ clData: String) -> (plain: String, hex: String)? {
        guard let raw = base64Decode(clData), raw.count % 16 == 0, !raw.isEmpty else { return nil }
        guard let dec = aesECBDecrypt(raw, key: aesKey) else { return nil }
        guard let plain = stripPadding(dec), !plain.isEmpty else { return nil }
        guard let dash = plain.firstIndex(of: "-") else { return nil }
        let hex = plain[plain.index(after: dash)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return hex.isEmpty ? nil : (plain, hex)
    }
}

// ══════════════════════════════════════════════════════
//  签名（对应 Android 端 KlcxkjSigner + BleSignBuilder）
// ══════════════════════════════════════════════════════
enum QzxySigner {

    /// 外层固定密钥（自带 &key= 前缀，不是笔误）
    static let outerKey = "&key=sign-kailu-855c74a88b8b494187c99b08b8c9a744"

    /// 内层 = MD5(raw + "&key=" + sessionKey)；签名 = MD5(内层 + outerKey)
    static func sign(sessionKey: String, raw: String) -> String? {
        guard !sessionKey.isEmpty else { return nil }
        let inner = QzxyCrypto.md5Hex(raw + "&key=" + sessionKey)
        return QzxyCrypto.md5Hex(inner + outerKey)
    }

    /// 按 key 字典序升序拼 key1value1key2value2…（value 为 nil 时整个字段跳过）
    static func rawOf(_ params: [String: String?]) -> String {
        params.keys.sorted().map { k in k + (params[k] ?? "") }.joined()
    }

    static func signRateOrder(loginCode: String, telephone: String,
                              deviceId: String, xfModel: String,
                              randomNumber: String) -> String? {
        sign(sessionKey: loginCode, raw: rawOf([
            "telephone": telephone, "deviceId": deviceId,
            "xfModel": xfModel, "randomNumber": randomNumber.lowercased()]))
    }

    static func signUpload(loginCode: String, telephone: String, xfData: String) -> String? {
        sign(sessionKey: loginCode, raw: rawOf([
            "loginCode": loginCode, "telephone": telephone,
            "xfData": xfData.lowercased()]))
    }

    static func signFail(loginCode: String, telephone: String, consumeDate: String) -> String? {
        sign(sessionKey: loginCode, raw: rawOf([
            "consumeDate": consumeDate, "loginCode": loginCode, "telephone": telephone]))
    }

    /// macType = "%02x%02x"（type 来自状态帧 p[19]，a1 来自 p[30]）
    static func macType(_ type: Int, _ a1: Int) -> String {
        String(format: "%02x%02x", UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: a1))
    }
}
