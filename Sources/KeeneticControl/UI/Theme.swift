import AppKit
import SwiftUI

/// Палитра живёт в коде, а не в ассетах — приложение собирается одним swift build.
enum Palette {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = dynamic(
        light: NSColor(srgbRed: 0.13, green: 0.40, blue: 0.86, alpha: 1),
        dark:  NSColor(srgbRed: 0.36, green: 0.60, blue: 1.00, alpha: 1))

    /// Фон окна.
    static let canvas = dynamic(
        light: NSColor(srgbRed: 0.957, green: 0.961, blue: 0.973, alpha: 1),
        dark:  NSColor(srgbRed: 0.086, green: 0.094, blue: 0.110, alpha: 1))

    /// Поверхность карточки.
    static let surface = dynamic(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark:  NSColor(srgbRed: 0.133, green: 0.145, blue: 0.169, alpha: 1))

    /// Вложенная поверхность — таблицы, поля, консоль.
    static let inset = dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 1),
        dark:  NSColor(srgbRed: 0.098, green: 0.106, blue: 0.126, alpha: 1))

    static let stroke = dynamic(
        light: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.89, alpha: 1),
        dark:  NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.10))

    static let success = dynamic(
        light: NSColor(srgbRed: 0.10, green: 0.58, blue: 0.32, alpha: 1),
        dark:  NSColor(srgbRed: 0.35, green: 0.82, blue: 0.52, alpha: 1))

    static let warning = dynamic(
        light: NSColor(srgbRed: 0.75, green: 0.48, blue: 0.05, alpha: 1),
        dark:  NSColor(srgbRed: 0.98, green: 0.72, blue: 0.28, alpha: 1))

    static let danger = dynamic(
        light: NSColor(srgbRed: 0.78, green: 0.19, blue: 0.19, alpha: 1),
        dark:  NSColor(srgbRed: 1.00, green: 0.44, blue: 0.42, alpha: 1))
}

// MARK: - Карточка

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: 1)
                    .allowsHitTesting(false))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardModifier(padding: padding)) }

    /// Мягкая подложка для вложенных блоков.
    func inset(cornerRadius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
                .allowsHitTesting(false))
    }
}

// MARK: - Заголовки

struct CardHeader: View {
    var icon: String
    var title: String
    var subtitle: String?
    var tint: Color = Palette.accent

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Плашки состояния

struct StatusPill: View {
    var text: String
    var tint: Color
    var icon: String?
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(filled ? tint : tint.opacity(0.13)))
    }
}

/// Живое состояние туннеля одной строкой: проверка связи и свежесть
/// рукопожатия. Пусто, если роутеру нечего сказать.
struct LiveStateLine: View {
    var check: PingCheckLiveState
    var handshake: Int?
    var online: Bool

    private var checkTint: Color {
        switch check {
        case .passing:                    return Palette.success
        case .failing:                    return Palette.danger
        case .unknown, .notConfigured:    return .secondary
        }
    }

    private var handshakeText: String? {
        guard online else { return nil }
        guard let handshake else { return "рукопожатия не было" }
        return "рукопожатие \(Format.ago(seconds: handshake))"
    }

    var body: some View {
        // Про проверку говорим, только когда роутер действительно ответил.
        // «Не знаю» — это не состояние туннеля, и выдавать его за состояние
        // нельзя: человек читает это как поломку.
        if check.isKnown || handshakeText != nil {
            HStack(spacing: 6) {
                if check.isKnown {
                    HStack(spacing: 4) {
                        Image(systemName: check == .passing
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 9))
                        Text(check.title).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(checkTint)
                    .help(check.explanation)
                }
                if let handshakeText {
                    if check.isKnown {
                        Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(handshakeText)
                        .font(.system(size: 10))
                        // Тишина дольше трёх минут — туннель уже не живой.
                        .foregroundStyle((handshake ?? .max) <= 180 ? .secondary : Palette.warning)
                }
            }
        }
    }
}

struct MetricTile: View {
    var value: String
    var label: String
    var icon: String
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .inset(cornerRadius: 12)
    }
}

// MARK: - Кнопки

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.4))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.22)))
            .contentShape(Rectangle())
    }
}

struct SubtleButtonStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Мелочи

struct KeyValueRow: View {
    var key: String
    var value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EmptyHint: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Однострочный прогресс с оценкой оставшегося времени.
struct ProgressBanner: View {
    var info: ProgressInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(info.label).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(info.done) / \(info.total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let eta = info.eta {
                    Text("· осталось ~\(eta)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: info.fraction)
                .progressViewStyle(.linear)
                .tint(Palette.accent)
        }
        .padding(14)
        .inset(cornerRadius: 12)
    }
}

/// Единый способ показать ошибку пользователю.
struct AlertPayload: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var isError: Bool = true
}
