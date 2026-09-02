import Foundation

enum Format {
    static func age(_ moment: Date) -> String {
        let delta = Date().timeIntervalSince(moment)
        if delta < 90 { return "только что" }
        if delta < 3600 { return "\(Int(delta / 60)) мин назад" }
        if delta < 86_400 { return "\(Int(delta / 3600)) ч назад" }
        return "\(Int(delta / 86_400)) дн назад"
    }

    /// «12 с назад», «3 мин назад» — для времени последнего рукопожатия.
    /// Точность до секунды нужна только в первую минуту: дальше она лишь
    /// удлиняет строку, и та переносится на две.
    static func ago(seconds: Int) -> String {
        if seconds < 5 { return "только что" }
        if seconds < 60 { return "\(seconds) с назад" }
        if seconds < 3600 { return "\(seconds / 60) мин назад" }
        if seconds < 86_400 { return "\(seconds / 3600) ч назад" }
        return "\(seconds / 86_400) дн назад"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total) с" }
        let minutes = total / 60, rest = total % 60
        if minutes < 60 { return String(format: "%d мин %02d с", minutes, rest) }
        return String(format: "%d ч %02d мин", minutes / 60, minutes % 60)
    }

    /// Русские окончания: 1 домен, 2 домена, 5 доменов.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        let word: String
        if (11...14).contains(mod100) { word = many }
        else if mod10 == 1 { word = one }
        else if (2...4).contains(mod10) { word = few }
        else { word = many }
        return "\(count) \(word)"
    }

    /// Согласование глагола с числом: «добавлен 1 домен», но
    /// «добавлено 2 домена». Без этого выходило «появилось 1 список».
    static func agree(_ count: Int, _ single: String, _ plural: String) -> String {
        let mod100 = count % 100, mod10 = count % 10
        if (11...14).contains(mod100) { return plural }
        return mod10 == 1 ? single : plural
    }

    static func domains(_ count: Int) -> String { plural(count, "домен", "домена", "доменов") }
    static func commands(_ count: Int) -> String { plural(count, "команда", "команды", "команд") }
    static func lists(_ count: Int) -> String { plural(count, "список", "списка", "списков") }
    /// Предложный падеж: «в 14 списках», а не «в 14 списков».
    static func inLists(_ count: Int) -> String { plural(count, "списке", "списках", "списках") }
    static func routes(_ count: Int) -> String { plural(count, "маршрут", "маршрута", "маршрутов") }

    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    static func humanDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM, HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: date)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
