import Foundation

/// SHA3-512 и HMAC поверх него. В CryptoKit семейства SHA3 нет, а схема
/// авторизации x-ndw4 роутеров Keenetic построена именно на нём.
/// Реализация прямая по FIPS 202: Keccak-f[1600], 24 раунда.
enum SHA3 {
    private static let rounds = 24

    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    /// Сдвиги шага ρ по индексу x + 5y.
    private static let rotations: [UInt64] = [
         0,  1, 62, 28, 27,
        36, 44,  6, 55, 20,
         3, 10, 43, 25, 39,
        41, 45, 15, 21,  8,
        18,  2, 61, 56, 14,
    ]

    @inline(__always)
    private static func rotl(_ value: UInt64, _ shift: UInt64) -> UInt64 {
        shift == 0 ? value : (value << shift) | (value >> (64 - shift))
    }

    private static func permute(_ lanes: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)

        for round in 0..<rounds {
            for x in 0..<5 {
                c[x] = lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20]
            }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in 0..<5 { lanes[x + 5 * y] ^= d }
            }

            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(lanes[x + 5 * y], rotations[x + 5 * y])
                }
            }

            for y in 0..<5 {
                for x in 0..<5 {
                    lanes[x + 5 * y] = b[x + 5 * y]
                        ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }

            lanes[0] ^= roundConstants[round]
        }
    }

    /// Губка с паддингом по домену SHA-3 (0x06 … 0x80).
    private static func sponge(_ message: [UInt8], rate: Int, outputLength: Int) -> [UInt8] {
        var lanes = [UInt64](repeating: 0, count: 25)

        var padded = message
        padded.append(0x06)
        while padded.count % rate != 0 { padded.append(0) }
        padded[padded.count - 1] |= 0x80

        for offset in stride(from: 0, to: padded.count, by: rate) {
            for lane in 0..<(rate / 8) {
                var value: UInt64 = 0
                for byte in 0..<8 {
                    value |= UInt64(padded[offset + lane * 8 + byte]) << UInt64(8 * byte)
                }
                lanes[lane] ^= value
            }
            permute(&lanes)
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(outputLength)
        while digest.count < outputLength {
            for lane in 0..<(rate / 8) where digest.count < outputLength {
                let value = lanes[lane]
                for byte in 0..<8 where digest.count < outputLength {
                    digest.append(UInt8((value >> UInt64(8 * byte)) & 0xFF))
                }
            }
            if digest.count < outputLength { permute(&lanes) }
        }
        return digest
    }

    /// Длина блока SHA3-512: (1600 − 2·512) бит.
    static let blockSize = 72
    static let digestSize = 64

    static func hash512(_ message: [UInt8]) -> [UInt8] {
        sponge(message, rate: blockSize, outputLength: digestSize)
    }

    static func hash512(_ text: String) -> [UInt8] { hash512(Array(text.utf8)) }

    /// HMAC-SHA3-512 по RFC 2104.
    static func hmac512(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var normalized = key.count > blockSize ? hash512(key) : key
        normalized.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalized.count))

        var inner = [UInt8](repeating: 0, count: blockSize)
        var outer = [UInt8](repeating: 0, count: blockSize)
        for index in 0..<blockSize {
            inner[index] = normalized[index] ^ 0x36
            outer[index] = normalized[index] ^ 0x5C
        }

        return hash512(outer + hash512(inner + message))
    }

    static func hmac512(key: [UInt8], message: String) -> [UInt8] {
        hmac512(key: key, message: Array(message.utf8))
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
