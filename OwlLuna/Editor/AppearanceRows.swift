import SwiftUI

/// The rows of More › View that set the app's appearance and whether paper stays light in Dark Mode, as Settings does.
struct AppearanceRows: View {
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .initial
    @AppStorage(SettingsKey.darkPaper) private var darkPaper = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        OwlLunaPicker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0) }
        }
        Button { darkPaper.toggle() } label: { Text("Keep Paper Light") }
            .menuChosen(!darkPaper)
            .disabled(scheme == .light)
    }
}
