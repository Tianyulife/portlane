import IndieCore
import SwiftUI

struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SteamPicker(title: "Language / 语言", selection: $language, choices: [("System / 跟随系统", "system"), ("English", "en"), ("简体中文", "zh-Hans")])
            Text("Reopen the app to apply. / 重新打开应用后生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
