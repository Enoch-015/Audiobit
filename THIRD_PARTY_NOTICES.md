# Third-Party Notices

Audibit uses or optionally downloads the following local speech and audio
components. Their licenses remain with their respective authors.

- **Kokoro-82M model weights** — Apache License 2.0  
  https://huggingface.co/hexgrad/Kokoro-82M
- **KokoroSwift** — MIT License  
  https://github.com/mlalma/kokoro-ios
- **MLX Swift** — MIT License  
  https://github.com/ml-explore/mlx-swift
- **MisakiSwift** — MIT License  
  https://github.com/mlalma/MisakiSwift
- **MLXUtilsLibrary** — MIT License  
  https://github.com/mlalma/MLXUtilsLibrary
- **Kokoro voice style assets** — distributed with the Apache-2.0-licensed
  Kokoro reference application  
  https://github.com/mlalma/KokoroTestApp
- **LAME MP3 encoder** — GNU Lesser General Public License 2.1
  https://lame.sourceforge.io/
- **Sparkle 2** — MIT License
  https://github.com/sparkle-project/Sparkle

The application does not transmit document contents to these projects or to
any external speech service.

KokoroSwift 1.0.8 and MisakiSwift 1.0.3 are vendored as static Swift Package
targets to ensure MLX is linked exactly once. Their original license files are
preserved under `Vendor/`.
