import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Form {
            Section("Software Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }
                    )
                )

                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: { updates.automaticallyDownloadsUpdates = $0 }
                    )
                )
                .disabled(!updates.automaticallyChecksForUpdates)

                Text("Audibit checks no more than once every 24 hours unless you check manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installed Version") {
                LabeledContent("Version", value: updates.installedVersion)
                LabeledContent("Last checked") {
                    if let date = updates.lastUpdateCheckDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text("Not yet")
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}
