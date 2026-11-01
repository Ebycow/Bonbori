// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Where the receiver is. Broadcasters read it from the NVRAM to show local weather and the like.
struct ReceiverRegion: Hashable {
    let name: String
    let prefecture: Int
    let regionCode: Int

    static let unset = ReceiverRegion(name: "未設定", prefecture: 255, regionCode: 0)

    static let all: [ReceiverRegion] = [
        unset,
        ReceiverRegion(name: "東北海道", prefecture: 1, regionCode: 0b000101101011),
        ReceiverRegion(name: "西北海道", prefecture: 2, regionCode: 0b000101101011),
        ReceiverRegion(name: "青森県", prefecture: 3, regionCode: 0b010001100111),
        ReceiverRegion(name: "岩手県", prefecture: 4, regionCode: 0b010111010100),
        ReceiverRegion(name: "宮城県", prefecture: 5, regionCode: 0b011101011000),
        ReceiverRegion(name: "秋田県", prefecture: 6, regionCode: 0b101011000110),
        ReceiverRegion(name: "山形県", prefecture: 7, regionCode: 0b111001001100),
        ReceiverRegion(name: "福島県", prefecture: 8, regionCode: 0b000110101110),
        ReceiverRegion(name: "茨城県", prefecture: 9, regionCode: 0b110001101001),
        ReceiverRegion(name: "栃木県", prefecture: 10, regionCode: 0b111000111000),
        ReceiverRegion(name: "群馬県", prefecture: 11, regionCode: 0b100110001011),
        ReceiverRegion(name: "埼玉県", prefecture: 12, regionCode: 0b011001001011),
        ReceiverRegion(name: "千葉県", prefecture: 13, regionCode: 0b000111000111),
        ReceiverRegion(name: "東京都(島部を除く)", prefecture: 14, regionCode: 0b101010101100),
        ReceiverRegion(name: "神奈川県", prefecture: 15, regionCode: 0b010101101100),
        ReceiverRegion(name: "新潟県", prefecture: 16, regionCode: 0b010011001110),
        ReceiverRegion(name: "富山県", prefecture: 17, regionCode: 0b010100111001),
        ReceiverRegion(name: "石川県", prefecture: 18, regionCode: 0b011010100110),
        ReceiverRegion(name: "福井県", prefecture: 19, regionCode: 0b100100101101),
        ReceiverRegion(name: "山梨県", prefecture: 20, regionCode: 0b110101001010),
        ReceiverRegion(name: "長野県", prefecture: 21, regionCode: 0b100111010010),
        ReceiverRegion(name: "岐阜県", prefecture: 22, regionCode: 0b101001100101),
        ReceiverRegion(name: "静岡県", prefecture: 23, regionCode: 0b101001011010),
        ReceiverRegion(name: "愛知県", prefecture: 24, regionCode: 0b100101100110),
        ReceiverRegion(name: "三重県", prefecture: 25, regionCode: 0b001011011100),
        ReceiverRegion(name: "滋賀県", prefecture: 26, regionCode: 0b110011100100),
        ReceiverRegion(name: "京都府", prefecture: 27, regionCode: 0b010110011010),
        ReceiverRegion(name: "大阪府", prefecture: 28, regionCode: 0b110010110010),
        ReceiverRegion(name: "兵庫県", prefecture: 29, regionCode: 0b011001110100),
        ReceiverRegion(name: "奈良県", prefecture: 30, regionCode: 0b101010010011),
        ReceiverRegion(name: "和歌山県", prefecture: 31, regionCode: 0b001110010110),
        ReceiverRegion(name: "鳥取県", prefecture: 32, regionCode: 0b110100100011),
        ReceiverRegion(name: "島根県", prefecture: 33, regionCode: 0b001100011011),
        ReceiverRegion(name: "岡山県", prefecture: 34, regionCode: 0b001010110101),
        ReceiverRegion(name: "広島県", prefecture: 35, regionCode: 0b101100110001),
        ReceiverRegion(name: "山口県", prefecture: 36, regionCode: 0b101110011000),
        ReceiverRegion(name: "徳島県", prefecture: 37, regionCode: 0b111001100010),
        ReceiverRegion(name: "香川県", prefecture: 38, regionCode: 0b100110110100),
        ReceiverRegion(name: "愛媛県", prefecture: 39, regionCode: 0b000110011101),
        ReceiverRegion(name: "高知県", prefecture: 40, regionCode: 0b001011100011),
        ReceiverRegion(name: "福岡県", prefecture: 41, regionCode: 0b011000101101),
        ReceiverRegion(name: "佐賀県", prefecture: 42, regionCode: 0b100101011001),
        ReceiverRegion(name: "長崎県", prefecture: 43, regionCode: 0b101000101011),
        ReceiverRegion(name: "熊本県", prefecture: 44, regionCode: 0b100010100111),
        ReceiverRegion(name: "大分県", prefecture: 45, regionCode: 0b110010001101),
        ReceiverRegion(name: "宮崎県", prefecture: 46, regionCode: 0b110100011100),
        ReceiverRegion(name: "鹿児島県(南西諸島を除く)", prefecture: 47, regionCode: 0b110101000101),
        ReceiverRegion(name: "沖縄県", prefecture: 48, regionCode: 0b001101110010),
        ReceiverRegion(name: "東京都島部(伊豆・小笠原諸島)", prefecture: 49, regionCode: 0b101010101100),
        ReceiverRegion(name: "鹿児島県島部(南西諸島の鹿児島県域)", prefecture: 50, regionCode: 0b110101000101),
    ]
}

/// A 郵便番号 as typed, in whatever width, with or without a hyphen.
enum ZipCode {
    enum Problem: Error, Equatable {
        case invalidCharacter(Character)
        case wrongLength

        var message: String {
            switch self {
            case .invalidCharacter(let c): return "郵便番号に使えない文字「\(c)」が含まれています。"
            case .wrongLength: return "郵便番号は 7 桁の数字にするか、空欄にしてください。"
            }
        }
    }

    /// Seven ASCII digits, or nothing.
    static func normalize(_ text: String) -> Result<String, Problem> {
        var digits = ""
        for c in text {
            if "-ー－".contains(c) { continue }
            guard c.isNumber, let value = c.wholeNumberValue else { return .failure(.invalidCharacter(c)) }
            digits.append(String(value))
        }
        guard digits.isEmpty || digits.count == 7 else { return .failure(.wrongLength) }
        return .success(digits)
    }
}

/// State of the 受信機の設定 sheet.
final class ReceiverSettingsModel: ObservableObject {
    @Published var zipCode: String
    @Published var region: ReceiverRegion
    @Published var problem: String?
    @Published var isConfirmingDelete = false

    init(zipCode: String, region: ReceiverRegion) {
        self.zipCode = zipCode
        self.region = region
    }
}

/// 受信機の設定: the NVRAM of the receiver.
struct ReceiverSettingsView: View {
    @ObservedObject var model: ReceiverSettingsModel
    let onSave: (String, ReceiverRegion) -> Void
    let onDeleteAll: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("郵便番号", text: $model.zipCode, prompt: Text("1000001"))
                Picker("地域", selection: $model.region) {
                    ForEach(ReceiverRegion.all, id: \.self) { Text($0.name).tag($0) }
                }
            }
            Text("データ放送の天気予報やニュースが地域を選ぶために使います。この Mac の中に保存され、通信機能を使わない限り外には送られません。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("保存領域をすべて削除…", role: .destructive) { model.isConfirmingDelete = true }
                Spacer()
                Button("キャンセル", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog("保存領域をすべて削除しますか?", isPresented: $model.isConfirmingDelete) {
            Button("削除", role: .destructive, action: onDeleteAll)
        } message: {
            Text("放送局がこの受信機に保存した内容（視聴ポイントなど）と、郵便番号・地域が消えます。")
        }
    }

    private func save() {
        switch ZipCode.normalize(model.zipCode) {
        case .success(let digits): onSave(digits, model.region)
        case .failure(let error): model.problem = error.message
        }
    }
}
