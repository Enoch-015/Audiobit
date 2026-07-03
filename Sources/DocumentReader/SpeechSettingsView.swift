import SwiftUI

struct SpeechSettingsView: View {
    @ObservedObject var speech: SpeechController
    @ObservedObject private var modelManager = KokoroModelManager.shared
    @State private var confirmInstall = false
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section("Speech Engine") {
                Picker("Reader", selection: engineBinding) {
                    Text(SpeechEngineKind.apple.displayName).tag(SpeechEngineKind.apple)
                    Text(SpeechEngineKind.kokoro.displayName)
                        .tag(SpeechEngineKind.kokoro)
                        .disabled(modelManager.state != .ready)
                }
                .pickerStyle(.radioGroup)

                Text("Mac Voices use the system speech service. Kokoro runs locally with MLX and uses more processing power.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Enhanced Voice — Kokoro") {
                switch modelManager.state {
                case .notInstalled:
                    LabeledContent("Download size", value: downloadSize)
                    Button("Install Enhanced Voice…") {
                        confirmInstall = true
                    }
                case .downloading, .verifying:
                    ProgressView(value: modelManager.progress) {
                        Text(modelManager.statusMessage)
                    }
                    Button("Cancel Download", role: .cancel) {
                        modelManager.cancelInstall()
                    }
                case .ready:
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Remove Enhanced Voice…", role: .destructive) {
                        confirmRemoval = true
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                    Button("Try Again") {
                        modelManager.install()
                    }
                }
            }

            Section("Voice") {
                Picker("Voice", selection: $speech.voiceIdentifier) {
                    Text("System Default").tag(String?.none)
                    ForEach(speech.voices) { voice in
                        Text("\(voice.name) — \(voice.language)")
                            .tag(Optional(voice.id))
                    }
                }
                Slider(value: $speech.rate, in: 0.35...0.65) {
                    Text("Speaking rate")
                }
                Button("Preview Voice", action: speech.previewVoice)
                    .disabled(speech.isPreparing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .confirmationDialog(
            "Install Enhanced Voice?",
            isPresented: $confirmInstall
        ) {
            Button("Download \(downloadSize)") {
                modelManager.install()
            }
        } message: {
            Text("The Kokoro model will be stored in Application Support. Document text and generated audio remain on this Mac.")
        }
        .confirmationDialog(
            "Remove Enhanced Voice?",
            isPresented: $confirmRemoval
        ) {
            Button("Remove", role: .destructive) {
                speech.switchEngine(to: .apple)
                modelManager.uninstall()
            }
        }
    }

    private var engineBinding: Binding<SpeechEngineKind> {
        Binding(
            get: { speech.engineKind },
            set: { speech.switchEngine(to: $0) }
        )
    }

    private var downloadSize: String {
        ByteCountFormatter.string(
            fromByteCount: modelManager.manifest.assets.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
    }
}
