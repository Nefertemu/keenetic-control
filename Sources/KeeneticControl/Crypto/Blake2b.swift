import Foundation

/// BLAKE2b по RFC 7693. Нужен как строительный блок Argon2id: тот считает
/// им и начальный хеш, и блоки памяти переменной длины.
enum Blake2b {
    private static let iv: [UInt64] = [
        0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
        0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179,
    ]

    private static let sigma: [[Int]] = [
        [ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15],
        [14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3],
        [11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4],
        [ 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8],
        [ 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13],
        [ 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9],
        [12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11],
        [13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10],
        [ 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5],
        [10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0],
    ]

    @inline(__always)
    private static func rotr(_ value: UInt64, _ shift: UInt64) -> UInt64 {
        (value >> shift) | (value << (64 - shift))
    }

    @inline(__always)
    private static func mix(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int,
                            _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    private static func compress(_ h: inout [UInt64], _ block: [UInt8],
                                 counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            var value: UInt64 = 0
            for byte in 0..<8 { value |= UInt64(block[index * 8 + byte]) << UInt64(8 * byte) }
            m[index] = value
        }

        var v = h + iv
        v[12] ^= counter
        // Длина сообщения выше 2^64 байт нам не встретится, старшая половина нулевая.
        if last { v[14] = ~v[14] }

        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(&v, 0, 4,  8, 12, m[s[0]],  m[s[1]])
            mix(&v, 1, 5,  9, 13, m[s[2]],  m[s[3]])
            mix(&v, 2, 6, 10, 14, m[s[4]],  m[s[5]])
            mix(&v, 3, 7, 11, 15, m[s[6]],  m[s[7]])
            mix(&v, 0, 5, 10, 15, m[s[8]],  m[s[9]])
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(&v, 2, 7,  8, 13, m[s[12]], m[s[13]])
            mix(&v, 3, 4,  9, 14, m[s[14]], m[s[15]])
        }

        for index in 0..<8 { h[index] ^= v[index] ^ v[index + 8] }
    }

    /// Хеш произвольной длины 1…64 байта, без ключа.
    static func hash(_ message: [UInt8], length: Int) -> [UInt8] {
        precondition((1...64).contains(length), "BLAKE2b отдаёт от 1 до 64 байт")

        var h = iv
        h[0] ^= 0x01010000 ^ UInt64(length)

        var counter: UInt64 = 0
        var offset = 0

        // Все полные блоки, кроме последнего: последний обрабатываем с флагом.
        while message.count - offset > 128 {
            counter &+= 128
            compress(&h, Array(message[offset..<(offset + 128)]), counter: counter, last: false)
            offset += 128
        }

        var tail = Array(message[offset...])
        counter &+= UInt64(tail.count)
        tail.append(contentsOf: [UInt8](repeating: 0, count: 128 - tail.count))
        compress(&h, tail, counter: counter, last: true)

        var digest: [UInt8] = []
        digest.reserveCapacity(length)
        for word in h {
            for byte in 0..<8 where digest.count < length {
                digest.append(UInt8((word >> UInt64(8 * byte)) & 0xFF))
            }
        }
        return digest
    }

    /// H′ из спецификации Argon2: хеш произвольной длины, в том числе больше 64 байт.
    static func longHash(_ message: [UInt8], length: Int) -> [UInt8] {
        var prefixed = [UInt8]()
        prefixed.reserveCapacity(4 + message.count)
        let size = UInt32(length)
        for byte in 0..<4 { prefixed.append(UInt8((size >> UInt32(8 * byte)) & 0xFF)) }
        prefixed.append(contentsOf: message)

        if length <= 64 { return hash(prefixed, length: length) }

        var result: [UInt8] = []
        var block = hash(prefixed, length: 64)
        result.append(contentsOf: block[0..<32])

        var produced = 32
        while length - produced > 64 {
            block = hash(block, length: 64)
            result.append(contentsOf: block[0..<32])
            produced += 32
        }

        result.append(contentsOf: hash(block, length: length - produced))
        return result
    }
}
