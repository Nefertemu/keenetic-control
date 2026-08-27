import Darwin
import Foundation

/// Разбор адресов и подсетей — Keenetic принимает и то и другое наравне с доменами.
enum IPTools {
    static func isIPv4(_ text: String) -> Bool { parseIPv4(text) != nil }
    static func isIPv6(_ text: String) -> Bool { parseIPv6(text) != nil }
    static func isIP(_ text: String) -> Bool { isIPv4(text) || isIPv6(text) }

    static func parseIPv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func parseIPv6(_ text: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ok = bytes.withUnsafeMutableBytes { inet_pton(AF_INET6, text, $0.baseAddress) == 1 }
        return ok ? bytes : nil
    }

    static func formatIPv4(_ value: UInt32) -> String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    static func formatIPv6(_ bytes: [UInt8]) -> String {
        let storage = bytes
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = storage.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(INET6_ADDRSTRLEN)) }
        return String(cString: buffer)
    }

    /// «10.1.2.3/16» → «10.1.0.0/16». Хостовые биты гасим, как ipaddress(strict=False).
    static func normalizeNetwork(_ text: String) -> String? {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let host = String(parts[0])

        if let value = parseIPv4(host) {
            guard (0...32).contains(prefix) else { return nil }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
            return "\(formatIPv4(value & mask))/\(prefix)"
        }

        if var bytes = parseIPv6(host) {
            guard (0...128).contains(prefix) else { return nil }
            for index in 0..<16 {
                let bitsBefore = index * 8
                if bitsBefore >= prefix {
                    bytes[index] = 0
                } else if bitsBefore + 8 > prefix {
                    let keep = prefix - bitsBefore
                    bytes[index] &= UInt8(0xFF) << UInt8(8 - keep)
                }
            }
            return "\(formatIPv6(bytes))/\(prefix)"
        }

        return nil
    }

    /// Keenetic в `ip route` ждёт адрес и маску, а не длину префикса.
    static func ipv4CIDRToAddressMask(_ cidr: String) -> (address: String, mask: String)? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              let value = parseIPv4(String(parts[0])) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        return (formatIPv4(value & mask), formatIPv4(mask))
    }

    static func ipv4MaskToPrefix(_ mask: String) -> Int? {
        guard let value = parseIPv4(mask) else { return nil }
        let ones = value.nonzeroBitCount
        guard value == (ones == 0 ? 0 : ~UInt32(0) << (32 - UInt32(ones))) else { return nil }
        return ones
    }
}
