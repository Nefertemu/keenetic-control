import Foundation

/// RFC 3492. Нужен, чтобы кириллические домены уезжали на роутер
/// в том же виде, что и из консольного скрипта: xn--…
enum Punycode {
    private static let base: UInt32 = 36
    private static let tmin: UInt32 = 1
    private static let tmax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700
    private static let initialBias: UInt32 = 72
    private static let initialN: UInt32 = 128

    /// Кодирует одну метку домена. ASCII возвращается как есть.
    static func encode(label: String) -> String? {
        let input = Array(label.unicodeScalars)
        guard input.contains(where: { !$0.isASCII }) else { return label }

        var output = input.filter { $0.isASCII }.map { Character($0) }
        let basicCount = output.count
        if basicCount > 0 { output.append("-") }

        var handled = basicCount
        var n = initialN
        var delta: UInt64 = 0
        var bias = initialBias

        while handled < input.count {
            var minimum = UInt32.max
            for scalar in input where scalar.value >= n && scalar.value < minimum {
                minimum = scalar.value
            }
            guard minimum != UInt32.max else { return nil }

            delta += UInt64(minimum - n) * UInt64(handled + 1)
            guard delta <= UInt64(UInt32.max) else { return nil }
            n = minimum

            for scalar in input {
                if scalar.value < n {
                    delta += 1
                    guard delta <= UInt64(UInt32.max) else { return nil }
                }
                guard scalar.value == n else { continue }

                var q = delta
                var k = base
                while true {
                    let t: UInt32
                    if k <= bias { t = tmin }
                    else if k >= bias + tmax { t = tmax }
                    else { t = k - bias }

                    if q < UInt64(t) { break }
                    let digit = UInt32(t) + UInt32((q - UInt64(t)) % UInt64(base - t))
                    output.append(character(for: digit))
                    q = (q - UInt64(t)) / UInt64(base - t)
                    k += base
                }

                output.append(character(for: UInt32(q)))
                bias = adapt(delta: delta, numPoints: UInt32(handled + 1), firstTime: handled == basicCount)
                delta = 0
                handled += 1
            }

            delta += 1
            n += 1
        }

        return "xn--" + String(output)
    }

    /// Целиком доменное имя: каждую метку по отдельности.
    static func encode(domain: String) -> String? {
        guard domain.unicodeScalars.contains(where: { !$0.isASCII }) else { return domain }
        var parts: [String] = []
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard let encoded = encode(label: String(label)) else { return nil }
            parts.append(encoded)
        }
        return parts.joined(separator: ".")
    }

    private static func adapt(delta: UInt64, numPoints: UInt32, firstTime: Bool) -> UInt32 {
        var delta = firstTime ? delta / UInt64(damp) : delta / 2
        delta += delta / UInt64(numPoints)

        var k: UInt32 = 0
        let threshold = UInt64(((base - tmin) * tmax) / 2)
        while delta > threshold {
            delta /= UInt64(base - tmin)
            k += base
        }
        return k + UInt32((UInt64(base - tmin + 1) * delta) / (delta + UInt64(skew)))
    }

    private static func character(for digit: UInt32) -> Character {
        // 0..25 → a..z, 26..35 → 0..9
        let value = digit < 26 ? (digit + 97) : (digit - 26 + 48)
        return Character(UnicodeScalar(value)!)
    }
}
