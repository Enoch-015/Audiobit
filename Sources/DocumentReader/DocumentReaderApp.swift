import SwiftUI

@main
struct DocumentReaderApp: App {
    @StateObject private var speech = SpeechController()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup {
            RootView(speech: speech)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
            }
        }

        Settings {
            TabView {
                SpeechSettingsView(speech: speech)
                    .tabItem {
                        Label("Speech", systemImage: "waveform")
                    }
                UpdateSettingsView(updates: updates)
                    .tabItem {
                        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
            }
            .frame(width: 520, height: 430)
        }
    }
}
