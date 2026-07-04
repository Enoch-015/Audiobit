import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var documents = DocumentController()
    @StateObject private var audioExport = AudioExportController()
    @ObservedObject var speech: SpeechController
    @ObservedObject private var modelManager = KokoroModelManager.shared
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activateKokoroAfterInstall = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(documents: documents, speech: speech)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            DetailView(
                documents: documents,
                speech: speech,
                searchText: searchText,
                openAction: { showImporter = true },
                backAction: {
                    speech.stop()
                    documents.resetToStart()
                }
            )
        }
        .navigationTitle(documents.content?.title ?? "Audibit")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showImporter = true
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .keyboardShortcut("o")
                .help("Open a document")

                if documents.content != nil {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .accessibilityLabel("Search document")

                    Button {
                        if let content = documents.content {
                            audioExport.start(content: content, speech: speech)
                        }
                    } label: {
                        if audioExport.isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Export Audio", systemImage: "waveform.badge.plus")
                        }
                    }
                    .disabled(audioExport.isExporting)
                    .help("Export this document as an MP3")
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Speech settings")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: SupportedTypes.all + [.data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                documents.open(url)
            }
        }
        .onOpenURL { documents.open($0) }
        .onChange(of: documents.content) { _, content in
            guard let content else { return }
            let session = ReaderPersistence.shared.session(for: content.sourceURL)
            speech.load(content, sectionIndex: documents.selectedSectionIndex, session: session)
        }
        .onChange(of: speech.currentSectionIndex) { _, index in
            documents.selectedSectionIndex = index
        }
        .onChange(of: speech.rate) { _, _ in saveSpeechSession() }
        .onChange(of: speech.voiceIdentifier) { _, _ in saveSpeechSession() }
        .onChange(of: speech.engineKind) { _, _ in saveSpeechSession() }
        .onChange(of: modelManager.state) { _, state in
            guard state == .ready, activateKokoroAfterInstall else { return }
            activateKokoroAfterInstall = false
            speech.switchEngine(to: .kokoro)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            documents.open(url)
            return true
        }
        .alert(
            "Speech Playback",
            isPresented: Binding(
                get: { speech.fallbackMessage != nil },
                set: { if !$0 { speech.fallbackMessage = nil } }
            )
        ) {
            if modelManager.state != .ready,
               speech.fallbackMessage?.localizedCaseInsensitiveContains("not installed") == true {
                Button("Download Enhanced Voice (\(kokoroDownloadSize))") {
                    activateKokoroAfterInstall = true
                    speech.fallbackMessage = nil
                    modelManager.install()
                }
            } else if speech.fallbackMessage?.contains("Continue from here") == true {
                Button("Continue with Mac Voices") {
                    speech.continueWithAppleVoice()
                }
            }
            Button("Not Now", role: .cancel) {
                speech.fallbackMessage = nil
            }
        } message: {
            Text(speech.fallbackMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { audioExport.isExporting },
            set: { if !$0 { audioExport.cancel() } }
        )) {
            AudioExportProgressView(audioExport: audioExport)
        }
        .alert(
            "Audio Export",
            isPresented: Binding(
                get: {
                    if case .completed = audioExport.state { return true }
                    if case .failed = audioExport.state { return true }
                    return false
                },
                set: { if !$0 { audioExport.dismissResult() } }
            )
        ) {
            if case .completed(let url) = audioExport.state {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    audioExport.dismissResult()
                }
            }
            Button("OK") { audioExport.dismissResult() }
        } message: {
            switch audioExport.state {
            case .completed(let url):
                Text("Saved to \(url.path)")
            case .failed(let message):
                Text(message)
            default:
                EmptyView()
            }
        }
    }

    private func saveSpeechSession() {
        guard let url = documents.content?.sourceURL else { return }
        var session = ReaderPersistence.shared.session(for: url)
        session.sectionIndex = documents.selectedSectionIndex
        session.speechRate = speech.rate
        session.voiceIdentifier = speech.voiceIdentifier
        session.speechEngine = speech.engineKind
        ReaderPersistence.shared.save(session, for: url)
    }

    private var kokoroDownloadSize: String {
        ByteCountFormatter.string(
            fromByteCount: modelManager.manifest.assets.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
    }
}

private struct AudioExportProgressView: View {
    @ObservedObject var audioExport: AudioExportController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporting Audio")
                .font(.headline)
            if case .exporting(let progress, let message) = audioExport.state {
                ProgressView(value: progress)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    audioExport.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

private struct SidebarView: View {
    @ObservedObject var documents: DocumentController
    @ObservedObject var speech: SpeechController

    var body: some View {
        List(selection: Binding(
            get: { documents.selectedSectionIndex },
            set: { value in
                documents.selectedSectionIndex = value
                speech.moveToSection(value)
            }
        )) {
            if let content = documents.content {
                Section("Contents") {
                    ForEach(Array(content.sections.enumerated()), id: \.element.id) { index, section in
                        Label(section.title, systemImage: section.pageIndex == nil ? "text.alignleft" : "doc.text")
                            .tag(index)
                    }
                }
            }

            if !documents.recentDocuments.isEmpty {
                Section("Recent") {
                    ForEach(documents.recentDocuments) { recent in
                        Button {
                            documents.open(recent.url)
                        } label: {
                            Label(recent.url.lastPathComponent, systemImage: "doc")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(recent.url.path)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task {
                                    await documents.removeDocumentFromCache(recent.url)
                                }
                            } label: {
                                Label("Remove from Cache", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DetailView: View {
    @ObservedObject var documents: DocumentController
    @ObservedObject var speech: SpeechController
    let searchText: String
    let openAction: () -> Void
    let backAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch documents.state {
                case .empty:
                    EmptyReaderView(openAction: openAction)
                case .loading:
                    LoadingView(
                        progress: documents.progress,
                        message: documents.progressMessage,
                        cancel: documents.cancel
                    )
                case .failed(let message):
                    FailureView(message: message, openAction: openAction)
                case .ready:
                    if let content = documents.content {
                        DocumentSurface(
                            content: content,
                            selectedIndex: documents.selectedSectionIndex,
                            searchText: searchText
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let content = documents.content {
                Divider()
                PlaybackBar(
                    speech: speech,
                    content: content,
                    sectionCount: content.sections.count,
                    selectedIndex: Binding(
                        get: { documents.selectedSectionIndex },
                        set: {
                            documents.selectedSectionIndex = $0
                            speech.moveToSection($0)
                        }
                    ),
                    backAction: backAction
                )
            }
        }
    }
}

private struct DocumentSurface: View {
    let content: DocumentContent
    let selectedIndex: Int
    let searchText: String

    private var isPDF: Bool {
        content.typeIdentifier == UTType.pdf.identifier
    }

    private var isPPTX: Bool {
        content.typeIdentifier == (UTType(filenameExtension: "pptx")?.identifier ?? "org.openxmlformats.presentationml.presentation")
    }

    var body: some View {
        if isPDF {
            HSplitView {
                PDFReaderView(
                    url: content.sourceURL,
                    pageIndex: content.sections[safe: selectedIndex]?.pageIndex ?? 0
                )
                .frame(minWidth: 420)

                ReadingTextView(
                    content: content,
                    selectedIndex: selectedIndex,
                    searchText: searchText
                )
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
            }
        } else if isPPTX {
            if let section = content.sections[safe: selectedIndex],
               section.imageData != nil,
               section.displayText.isEmpty {
                SlideImageView(section: section)
            } else {
                HSplitView {
                    SlideImageView(section: content.sections[safe: selectedIndex])
                        .frame(minWidth: 420)

                    ReadingTextView(
                        content: content,
                        selectedIndex: selectedIndex,
                        searchText: searchText
                    )
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
                }
            }
        } else {
            ReadingTextView(
                content: content,
                selectedIndex: selectedIndex,
                searchText: searchText
            )
        }
    }
}

private struct ReadingTextView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: DocumentContent
    let selectedIndex: Int
    let searchText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(content.sections.enumerated()), id: \.element.id) { index, section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            if !section.displayText.isEmpty {
                                Text(section.displayText)
                                    .font(.system(size: 16))
                                    .lineSpacing(5)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 760, alignment: .leading)
                        .background(index == selectedIndex ? Color.accentColor.opacity(0.08) : .clear)
                        .overlay(alignment: .leading) {
                            if index == selectedIndex {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: 3)
                            }
                        }
                        .opacity(matchesSearch(section) ? 1 : 0.3)
                        .id(index)
                        if index < content.sections.count - 1 {
                            Divider().padding(.horizontal, 28)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: selectedIndex) { _, index in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func matchesSearch(_ section: ReadingSection) -> Bool {
        searchText.isEmpty ||
            section.displayText.localizedCaseInsensitiveContains(searchText) ||
            section.title.localizedCaseInsensitiveContains(searchText)
    }
}

private struct SlideImageView: View {
    let section: ReadingSection?

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let section, let data = section.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No slide image available")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PlaybackBar: View {
    @ObservedObject var speech: SpeechController
    @ObservedObject private var modelManager = KokoroModelManager.shared
    let content: DocumentContent
    let sectionCount: Int
    @Binding var selectedIndex: Int
    let backAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: backAction) {
                Label("Back", systemImage: "chevron.left")
            }
            .help("Return to the start page and reupload a document")

            Button(action: speech.previousSection) {
                Image(systemName: "backward.end.fill")
            }
            .disabled(selectedIndex == 0)
            .help("Previous section")

            Button(action: speech.togglePlayback) {
                if speech.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18)
                } else {
                    Image(systemName: speech.isSpeaking && !speech.isPaused ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(speech.isPreparing)
            .keyboardShortcut(.space, modifiers: [])
            .help(speech.isSpeaking ? "Pause" : "Read aloud")

            Button(action: speech.nextSection) {
                Image(systemName: "forward.end.fill")
            }
            .disabled(selectedIndex >= sectionCount - 1)
            .help("Next section")

            Slider(
                value: Binding(
                    get: { Double(selectedIndex) },
                    set: { selectedIndex = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, sectionCount - 1)),
                step: 1
            )
            .accessibilityLabel("Reading position")

            Text("\(selectedIndex + 1) of \(sectionCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 58)

            Text(playbackLocationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 160, alignment: .leading)

            Menu {
                if modelManager.state != .ready {
                    switch modelManager.state {
                    case .downloading, .verifying:
                        Text(modelManager.statusMessage)
                        Button("Cancel Enhanced Voice Download", role: .destructive) {
                            modelManager.cancelInstall()
                        }
                    case .failed:
                        Button("Retry Enhanced Voice Download") {
                            modelManager.install()
                        }
                    case .notInstalled:
                        Button("Download Enhanced Voice (\(kokoroDownloadSize))") {
                            modelManager.install()
                        }
                    case .ready:
                        EmptyView()
                    }
                    Divider()
                }

                Picker("Speech Engine", selection: Binding(
                    get: { speech.engineKind },
                    set: { speech.switchEngine(to: $0) }
                )) {
                    Text("Mac Voices").tag(SpeechEngineKind.apple)
                    Text("Enhanced Voice — Kokoro")
                        .tag(SpeechEngineKind.kokoro)
                        .disabled(KokoroModelManager.shared.state != .ready)
                }
                Divider()
                Picker("Voice", selection: $speech.voiceIdentifier) {
                    Text("System Default").tag(String?.none)
                    ForEach(speech.voices) { voice in
                        Text("\(voice.name) — \(voice.language)")
                            .tag(Optional(voice.id))
                    }
                }
                Divider()
                Slider(value: $speech.rate, in: 0.35...0.65) {
                    Text("Speaking rate")
                }
                .frame(width: 180)
            } label: {
                Label(speech.engineKind.displayName, systemImage: "waveform")
            }
            .menuStyle(.borderlessButton)
            .help("Voice and speaking rate")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.bar)
    }

    private var kokoroDownloadSize: String {
        ByteCountFormatter.string(
            fromByteCount: modelManager.manifest.assets.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
    }

    private var playbackLocationText: String {
        guard content.sections.indices.contains(selectedIndex) else {
            return "Playback location unavailable"
        }

        let section = content.sections[selectedIndex]
        let pageText = section.pageIndex.map { "Page \($0 + 1)" } ?? section.title
        return "Playing to \(pageText)"
    }
}

private struct EmptyReaderView: View {
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a document")
                .font(.title2)
            Text("Drop a PDF, text document, or image here.")
                .foregroundStyle(.secondary)
            Button("Reupload / Choose File…", action: openAction)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LoadingView: View {
    let progress: Double
    let message: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .frame(width: 260)
            Text(message)
                .foregroundStyle(.secondary)
            Button("Cancel", action: cancel)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FailureView: View {
    let message: String
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Couldn’t open this document")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Another File…", action: openAction)
        }
        .padding(32)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
