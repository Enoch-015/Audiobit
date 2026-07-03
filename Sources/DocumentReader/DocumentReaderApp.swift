import SwiftUI

@main
struct DocumentReaderApp: App {
    @StateObject private var speech = SpeechController()

    var body: some Scene {
        WindowGroup {
            RootView(speech: speech)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SpeechSettingsView(speech: speech)
        }
    }
}
