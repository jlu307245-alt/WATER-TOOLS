//
//  BleFrameCodec.swift
//  水表设备帧编解码（对应 Android 端 BleFrame.kt）
//
//  二进制帧:  0x60 0x00 (len+3) 0x80 cmd 0x00 data... crc 0x16
//    · len = data.count + 3
//    · crc = (sum(data) + 0x80 + cmd) % 256
//  线上帧:    '#' + 大写HEX文本 + '\n'   ← 写特征的必须是这个，不是裸二进制
//
import Foundation

enum BleCmd {
    static let query: UInt8     = 0x23
    static let rate: UInt8      = 0x21
    static let close: UInt8     = 0x22
    static let collect: UInt8   = 0x85
    static let writeBack: UInt8 = 0x86
}

enum BleFrameCodec {
    static let head: UInt8 = 0x60
    static let tail: UInt8 = 0x16
    static let flag: UInt8 = 0x80
    static let wireStart: UInt8 = 0x23   // '#'
    static let wireEnd: UInt8   = 0x0A   // '\n'
    static let ackOK: UInt8     = 0x80

    static func build(cmd: UInt8, data: Data = Data()) -> Data {
        var f = Data()
        f.append(head)
        f.append(0x00)
        f.append(UInt8(truncatingIfNeeded: data.count + 3))
        f.append(flag)
        f.append(cmd)
        f.append(0x00)
        f.append(data)
        let sum = data.reduce(0) { $0 + Int($1) }
        f.append(UInt8((sum + Int(flag) + Int(cmd)) % 256))
        f.append(tail)
        return f
    }

    static func toWire(_ frame: Data) -> Data {
        let hex = frame.map { String(format: "%02X", $0) }.joined()
        var out = Data([wireStart])
        out.append(contentsOf: hex.utf8)
        out.append(wireEnd)
        return out
    }

    static func cmdToWire(cmd: UInt8, data: Data = Data()) -> Data {
        toWire(build(cmd: cmd, data: data))
    }

    static func fromHex(_ s: String) -> Data? {
        let clean = s.lowercased().replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out = Data()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    static func toHex(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined()
    }

    /// 从接收缓冲切出一条完整帧（以 '\n' 结尾）
    /// 返回 (cmd, payload, 已消费字节数)
    static func parseWire(_ buf: Data) -> (cmd: UInt8, payload: Data, consumed: Int)? {
        guard let nl = buf.firstIndex(of: wireEnd) else { return nil }
        let consumed = nl + 1
        var line = buf.subdata(in: 0..<nl)
        // 去掉空白
        while let first = line.first, first == 0x20 || first == 0x0D {
            line.removeFirst()
        }
        if line.first == wireStart { line.removeFirst() }
        guard let frame = fromHex(String(data: line, encoding: .utf8) ?? "") else { return nil }
        guard frame.count >= 8, frame[0] == head, frame[frame.count - 1] == tail else { return nil }
        let cmd = frame[4]
        let payload = frame.subdata(in: 6..<(frame.count - 2))
        return (cmd, payload, consumed)
    }
}

// ══════════════════════════════════════════════════════
//  设备状态帧解析（0x23 应答）
// ══════════════════════════════════════════════════════
struct DeviceQueryState {
    let protocolType: String   // p[19]
    let randomNumber: String   // p[24..27] —— 服务端签名必需，不能本地生成
    let state: UInt8           // p[28]  0=空闲 1=使用中 3/6=有遗留未结算记录
    let devType: UInt8         // p[29]
    let a1: UInt8              // p[30]

    var stateName: String {
        switch state {
        case 0: return "空闲"
        case 1: return "使用中（阀开）"
        case 3, 6: return "有遗留未结算记录"
        default: return "未知(\(state))"
        }
    }

    static func parse(_ p: Data) -> DeviceQueryState? {
        guard p.count >= 31 else { return nil }
        return DeviceQueryState(
            protocolType: String(format: "%02X", p[19]),
            randomNumber: p.subdata(in: 24..<28).map { String(format: "%02x", $0) }.joined(),
            state: p[28],
            devType: p[29],
            a1: p[30]
        )
    }
}
