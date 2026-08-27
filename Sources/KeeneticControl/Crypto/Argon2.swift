import Foundation

/// Argon2id по RFC 9106. Нужен для схемы входа x-ndw4: роутер присылает соль
/// и параметры, а из пароля выводится ключ, на котором дальше строится
/// SCRAM-обмен. В системных библиотеках macOS Argon2 нет.
struct Argon2Error: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Argon2 {
    private static let wordsPerBlock = 128          // 1024 байта
    private static let syncPoints = 4
    private static let addressesPerBlock = 128
    private static let version: UInt32 = 0x13
    private static let typeArgon2id: UInt32 = 2

    struct Parameters {
        var iterations: Int
        var memoryKiB: Int
        var parallelism: Int
        var tagLength: Int
    }

    // MARK: - Примитивы

    @inline(__always)
    private static func rotr(_ value: UInt64, _ shift: UInt64) -> UInt64 {
        (value >> shift) | (value << (64 - shift))
    }

    /// Умножение младших половин — то самое отличие BlaMka от BLAKE2b.
    @inline(__always)
    private static func blaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        let product = UInt64(UInt32(truncatingIfNeeded: x)) &* UInt64(UInt32(truncatingIfNeeded: y))
        return x &+ y &+ (product &<< 1)
    }

    @inline(__always)
    private static func mix(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        v[a] = blaMka(v[a], v[b])
        v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = blaMka(v[c], v[d])
        v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = blaMka(v[a], v[b])
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = blaMka(v[c], v[d])
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    @inline(__always)
    private static func roundP(_ v: inout [UInt64]) {
        mix(&v, 0, 4,  8, 12)
        mix(&v, 1, 5,  9, 13)
        mix(&v, 2, 6, 10, 14)
        mix(&v, 3, 7, 11, 15)
        mix(&v, 0, 5, 10, 15)
        mix(&v, 1, 6, 11, 12)
        mix(&v, 2, 7,  8, 13)
        mix(&v, 3, 4,  9, 14)
    }

    /// G(X, Y): раунды по строкам, затем по столбцам, и XOR с исходным.
    private static func compress(_ x: UnsafePointer<UInt64>, _ y: UnsafePointer<UInt64>,
                                 into out: UnsafeMutablePointer<UInt64>, accumulate: Bool) {
        var r = [UInt64](repeating: 0, count: wordsPerBlock)
        for index in 0..<wordsPerBlock { r[index] = x[index] ^ y[index] }
        var z = r

        var lane = [UInt64](repeating: 0, count: 16)

        for row in 0..<8 {
            let base = row * 16
            for index in 0..<16 { lane[index] = z[base + index] }
            roundP(&lane)
            for index in 0..<16 { z[base + index] = lane[index] }
        }

        for column in 0..<8 {
            for pair in 0..<8 {
                lane[2 * pair]     = z[2 * column + 16 * pair]
                lane[2 * pair + 1] = z[2 * column + 16 * pair + 1]
            }
            roundP(&lane)
            for pair in 0..<8 {
                z[2 * column + 16 * pair]     = lane[2 * pair]
                z[2 * column + 16 * pair + 1] = lane[2 * pair + 1]
            }
        }

        if accumulate {
            for index in 0..<wordsPerBlock { out[index] = out[index] ^ z[index] ^ r[index] }
        } else {
            for index in 0..<wordsPerBlock { out[index] = z[index] ^ r[index] }
        }
    }

    // MARK: - Вспомогательное

    private static func appendLE32(_ value: Int, to bytes: inout [UInt8]) {
        let word = UInt32(truncatingIfNeeded: value)
        for shift in 0..<4 { bytes.append(UInt8((word >> UInt32(8 * shift)) & 0xFF)) }
    }

    private static func words(from bytes: [UInt8]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: bytes.count / 8)
        for index in 0..<result.count {
            var value: UInt64 = 0
            for byte in 0..<8 { value |= UInt64(bytes[index * 8 + byte]) << UInt64(8 * byte) }
            result[index] = value
        }
        return result
    }

    private static func bytes(from words: ArraySlice<UInt64>) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(words.count * 8)
        for value in words {
            for byte in 0..<8 { result.append(UInt8((value >> UInt64(8 * byte)) & 0xFF)) }
        }
        return result
    }

    // MARK: - Основной алгоритм

    static func hash(password: [UInt8], salt: [UInt8],
                     secret: [UInt8] = [], associated: [UInt8] = [],
                     parameters: Parameters) throws -> [UInt8] {
        let lanes = parameters.parallelism
        guard lanes >= 1, parameters.iterations >= 1, parameters.tagLength >= 4 else {
            throw Argon2Error("Некорректные параметры Argon2id от роутера.")
        }

        var totalBlocks = parameters.memoryKiB
        if totalBlocks < 8 * lanes { totalBlocks = 8 * lanes }
        let segmentLength = totalBlocks / (lanes * syncPoints)
        guard segmentLength >= 1 else {
            throw Argon2Error("Argon2id: слишком мало памяти в параметрах роутера.")
        }
        let laneLength = segmentLength * syncPoints
        totalBlocks = laneLength * lanes

        // H0 — свёртка всех параметров и входных данных.
        var prologue = [UInt8]()
        appendLE32(lanes, to: &prologue)
        appendLE32(parameters.tagLength, to: &prologue)
        appendLE32(parameters.memoryKiB, to: &prologue)
        appendLE32(parameters.iterations, to: &prologue)
        appendLE32(Int(version), to: &prologue)
        appendLE32(Int(typeArgon2id), to: &prologue)
        appendLE32(password.count, to: &prologue);   prologue += password
        appendLE32(salt.count, to: &prologue);       prologue += salt
        appendLE32(secret.count, to: &prologue);     prologue += secret
        appendLE32(associated.count, to: &prologue); prologue += associated
        let h0 = Blake2b.hash(prologue, length: 64)

        var memory = [UInt64](repeating: 0, count: totalBlocks * wordsPerBlock)

        // Первые два блока каждой полосы выводятся напрямую из H0.
        for lane in 0..<lanes {
            for column in 0..<2 {
                var seed = h0
                appendLE32(column, to: &seed)
                appendLE32(lane, to: &seed)
                let block = words(from: Blake2b.longHash(seed, length: 1024))
                let offset = (lane * laneLength + column) * wordsPerBlock
                for index in 0..<wordsPerBlock { memory[offset + index] = block[index] }
            }
        }

        let zeroBlock = [UInt64](repeating: 0, count: wordsPerBlock)
        var inputBlock = [UInt64](repeating: 0, count: wordsPerBlock)
        var addressBlock = [UInt64](repeating: 0, count: wordsPerBlock)
        var scratch = [UInt64](repeating: 0, count: wordsPerBlock)

        func nextAddresses() {
            inputBlock[6] &+= 1
            zeroBlock.withUnsafeBufferPointer { zero in
                inputBlock.withUnsafeBufferPointer { input in
                    scratch.withUnsafeMutableBufferPointer { out in
                        compress(zero.baseAddress!, input.baseAddress!,
                                 into: out.baseAddress!, accumulate: false)
                    }
                }
            }
            zeroBlock.withUnsafeBufferPointer { zero in
                scratch.withUnsafeBufferPointer { input in
                    addressBlock.withUnsafeMutableBufferPointer { out in
                        compress(zero.baseAddress!, input.baseAddress!,
                                 into: out.baseAddress!, accumulate: false)
                    }
                }
            }
        }

        /// Выбор опорного блока — самая капризная часть спецификации.
        func referenceIndex(pass: Int, slice: Int, index: Int,
                            sameLane: Bool, random: UInt64) -> Int {
            var areaSize: UInt32
            if pass == 0 {
                if slice == 0 {
                    areaSize = UInt32(index) &- 1
                } else if sameLane {
                    areaSize = UInt32(slice * segmentLength + index) &- 1
                } else {
                    areaSize = UInt32(slice * segmentLength) &- (index == 0 ? 1 : 0)
                }
            } else if sameLane {
                areaSize = UInt32(laneLength - segmentLength + index) &- 1
            } else {
                areaSize = UInt32(laneLength - segmentLength) &- (index == 0 ? 1 : 0)
            }

            var relative = random & 0xFFFF_FFFF
            relative = (relative &* relative) >> 32
            relative = UInt64(areaSize) &- 1 &- ((UInt64(areaSize) &* relative) >> 32)

            var start = 0
            if pass != 0 { start = slice == syncPoints - 1 ? 0 : (slice + 1) * segmentLength }
            return Int((UInt64(start) &+ relative) % UInt64(laneLength))
        }

        for pass in 0..<parameters.iterations {
            for slice in 0..<syncPoints {
                // Argon2id: первая половина первого прохода — независимая
                // от данных адресация, дальше — зависимая.
                let dataIndependent = (pass == 0 && slice < syncPoints / 2)

                for lane in 0..<lanes {
                    if dataIndependent {
                        for index in 0..<wordsPerBlock { inputBlock[index] = 0 }
                        inputBlock[0] = UInt64(pass)
                        inputBlock[1] = UInt64(lane)
                        inputBlock[2] = UInt64(slice)
                        inputBlock[3] = UInt64(totalBlocks)
                        inputBlock[4] = UInt64(parameters.iterations)
                        inputBlock[5] = UInt64(typeArgon2id)
                    }

                    var startingIndex = 0
                    if pass == 0 && slice == 0 {
                        startingIndex = 2
                        if dataIndependent { nextAddresses() }
                    }

                    var current = lane * laneLength + slice * segmentLength + startingIndex
                    var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1

                    for index in startingIndex..<segmentLength {
                        if current % laneLength == 1 { previous = current - 1 }

                        let random: UInt64
                        if dataIndependent {
                            if index % addressesPerBlock == 0 { nextAddresses() }
                            random = addressBlock[index % addressesPerBlock]
                        } else {
                            random = memory[previous * wordsPerBlock]
                        }

                        var referenceLane = Int((random >> 32) % UInt64(lanes))
                        if pass == 0 && slice == 0 { referenceLane = lane }

                        let referenceColumn = referenceIndex(
                            pass: pass, slice: slice, index: index,
                            sameLane: referenceLane == lane, random: random)

                        let referenceOffset = (referenceLane * laneLength + referenceColumn) * wordsPerBlock
                        let previousOffset = previous * wordsPerBlock
                        let currentOffset = current * wordsPerBlock

                        memory.withUnsafeMutableBufferPointer { buffer in
                            let base = buffer.baseAddress!
                            compress(base + previousOffset, base + referenceOffset,
                                     into: base + currentOffset, accumulate: pass != 0)
                        }

                        current += 1
                        previous += 1
                    }
                }
            }
        }

        // Финал: XOR последних блоков всех полос.
        var final = [UInt64](repeating: 0, count: wordsPerBlock)
        for lane in 0..<lanes {
            let offset = (lane * laneLength + laneLength - 1) * wordsPerBlock
            for index in 0..<wordsPerBlock { final[index] ^= memory[offset + index] }
        }

        return Blake2b.longHash(bytes(from: final[0...]), length: parameters.tagLength)
    }
}
