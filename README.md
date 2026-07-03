# Audiobit

A private macOS document reader built with SwiftUI, PDFKit, Vision, and local
speech. Mac Voices work immediately; optional Kokoro Enhanced Voice runs
on-device through MLX after a one-click model download.

## Run

Open `Package.swift` in Xcode and run the `DocumentReader` scheme, or use:

```sh
swift run DocumentReader
```

To create a normal Finder-launchable app with **Open With** support:

```sh
./Scripts/build-app.sh
open .build/app/DocumentReader.app
```

Building Kokoro support requires Xcode's Metal Toolchain component:

```sh
xcodebuild -downloadComponent MetalToolchain
```

The app requires macOS 15 or newer on Apple Silicon. It supports PDF (including
OCR for scanned pages), TXT, Markdown, RTF, PNG, JPEG, TIFF, and HEIC.
Documents and generated audio stay on the Mac.

Kokoro model weights are Apache-2.0 licensed. KokoroSwift, MLX Swift,
MisakiSwift, and MLXUtilsLibrary retain their respective upstream licenses;
see `THIRD_PARTY_NOTICES.md`.
