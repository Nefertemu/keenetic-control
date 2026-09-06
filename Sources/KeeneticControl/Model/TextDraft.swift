/// Черновик сохраняет ввод при фоновом перечитывании исходного значения.
struct TextDraft {
    var text = ""
    private(set) var saved = ""

    mutating func receive(_ value: String) {
        if text == saved { text = value }
        saved = value
    }

    mutating func reset(to value: String) {
        saved = value
        text = value
    }
}
