# Third-party notices

- Flutter / Dart: BSD 3-Clause; Flutter license included in licenses/Flutter-BSD.txt. Engine and third-party notices also ship inside the framework / flutter_assets NOTICES.Z.
- whisper.cpp and ggml: MIT; copyright Georgi Gerganov and contributors, license included in licenses/whisper.cpp-MIT.txt.
- Silero VAD v5.1.2 model weights: MIT; copyright Silero Team, license included in licenses/Silero-VAD-MIT.txt. The macOS installer bundles the GGML conversion from the official ggml-org/whisper-vad repository; assets/vad-model.json records its pinned revision, source, size, and SHA256.
- Whisper model weights: OpenAI MIT, fetched from the traceable ggerganov/whisper.cpp converted GGML repository. The manifest records license and source. Weights are not included in the default installer.
- ffi, crypto, path: Dart packages, BSD 3-Clause notices are embedded by Flutter in NOTICES.Z.
- Material icons: Apache 2.0, distributed with Flutter. Apple system fonts are used on-device, not redistributed.

The project test entry accepts user-provided WAV files. No audio sample is bundled in the distributable or committed source.
