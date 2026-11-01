// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// 文字入力: what a BML document asks of the character input of a TV.
struct TextInputRequest {
    var characterType: String
    var allowedCharacters: String?
    var maxLength: Int
    var value: String
    var isPassword: Bool
    var isMultiline: Bool

    init?(_ message: [String: Any]) {
        guard let characterType = message["characterType"] as? String, let maxLength = message["maxLength"] as? Int else { return nil }
        self.characterType = characterType
        self.maxLength = maxLength
        allowedCharacters = message["allowedCharacters"] as? String
        value = message["value"] as? String ?? ""
        isPassword = message["inputMode"] as? String == "password"
        isMultiline = message["multiline"] as? Bool ?? false
    }

    private static let descriptions = [
        "number": "半角数字",
        "alphabet": "半角英字と半角記号",
        "hankaku": "半角英数と半角記号",
        "zenkaku": "全角ひらがなと全角カタカナと全角英数と全角記号",
        "katakana": "全角カタカナと全角記号",
        "hiragana": "全角ひらがなと全角記号",
    ]

    /// What is wrong with `text`, if anything.
    func problem(with text: String) -> String? {
        if maxLength > 0, text.utf16.count > maxLength { return "\(maxLength) 文字以内で入力してください。" }
        guard let allowedCharacters, let bad = text.first(where: { !allowedCharacters.contains($0) }) else { return nil }
        let hint = TextInputRequest.descriptions[characterType].map { "\($0)のみ入力できます。" } ?? ""
        return "入力できない文字「\(bad)」が含まれています。\(hint)"
    }
}

/// Asks for text in a sheet on the window. The system's input methods work as anywhere else.
final class TextInputSheet: NSObject {
    private let request: TextInputRequest
    private let completion: (String?) -> Void
    private let alert = NSAlert()
    private let field: NSTextField
    private let message = NSTextField(wrappingLabelWithString: "")
    private var isFinished = false

    init(_ request: TextInputRequest, completion: @escaping (String?) -> Void) {
        self.request = request
        self.completion = completion
        field = request.isPassword ? NSSecureTextField() : NSTextField()
        super.init()
    }

    func begin(on window: NSWindow) {
        alert.messageText = "文字の入力"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        field.stringValue = request.value
        // room below the field for what `confirm` has to say
        let messageHeight: CGFloat = 32
        field.frame = NSRect(x: 0, y: messageHeight, width: 300, height: request.isMultiline ? 80 : 24)
        field.usesSingleLineMode = !request.isMultiline
        field.cell?.wraps = request.isMultiline
        message.textColor = .systemRed
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.frame = NSRect(x: 0, y: 0, width: 300, height: messageHeight - 4)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: field.frame.maxY))
        accessory.addSubview(field)
        accessory.addSubview(message)
        alert.accessoryView = accessory
        // stays open until the text is good
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(confirm(_:))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [self] response in
            finish(response == .OK ? field.stringValue : nil)
        }
    }

    @objc private func confirm(_ sender: NSButton) {
        if let problem = request.problem(with: field.stringValue) {
            message.stringValue = problem
            return
        }
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .OK)
    }

    /// The document no longer wants the input.
    func cancel() {
        isFinished = true
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
    }

    private func finish(_ text: String?) {
        guard !isFinished else { return }
        isFinished = true
        completion(text)
    }
}
