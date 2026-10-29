# Notice

Sotto is free software under the GNU General Public License, version 3. See [LICENSE](LICENSE).

Copyright (C) 2026 Andrei Stolojan, for the changes made in Sotto.

## Upstream

Sotto is a modified version of [VoiceInk](https://github.com/Beingpax/VoiceInk) v2.21 (commit `640b0c8`) by Prakash Joshi and the VoiceInk contributors, released under the GNU General Public License, version 3. Most of the code in this repository comes from VoiceInk. The [README](README.md#fork-of-voiceink) lists what Sotto changed.

VoiceInk is the name of Prakash Joshi's own app. Sotto does not use the VoiceInk name, logo or icon as its own.

## Swift packages

Versions are pinned in `Voce.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. The full license texts of everything Sotto bundles are in [Voce/Resources/THIRD_PARTY_LICENSES.md](Voce/Resources/THIRD_PARTY_LICENSES.md), which also ships inside the app.

| Package | License |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 |
| [Transcribe-cpp-swift](https://github.com/Beingpax/Transcribe-cpp-swift), packaging [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) | MIT |
| [LLMkit](https://github.com/Beingpax/LLMkit) | MIT |
| [SelectedTextKit](https://github.com/Beingpax/SelectedTextKit), fork of [tisfeng/SelectedTextKit](https://github.com/tisfeng/SelectedTextKit) | MIT |
| [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) by ejbills, based on [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) | No license file; ungive's project is BSD 3-Clause |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui), [NetworkImage](https://github.com/gonzalezreal/NetworkImage) | MIT |
| [AXSwift](https://github.com/tisfeng/AXSwift) | MIT |
| [KeySender](https://github.com/jordanbaird/KeySender) | MIT |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | BSD 2-Clause and MIT |
| [swift-atomics](https://github.com/apple/swift-atomics) | Apache 2.0 |

## Downloaded at build time

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.8.2 XCFramework, MIT. `scripts/build.sh` downloads the official release and checks its SHA-256.

## Bundled files

- `Voce/Resources/models/ggml-silero-v5.1.2.bin`: [Silero VAD](https://github.com/snakers4/silero-vad) in whisper.cpp's format, MIT.
- `Voce/Resources/Sounds/feather-start.wav` and `feather-stop.wav`: adapted from [Kenney Interface Sounds](https://kenney.nl/assets/interface-sounds), CC0. Details in `Voce/Resources/Sounds/Feather-tap-license.txt`.
- The other recording sounds in `Voce/Resources/Sounds/` come from VoiceInk.
- `Voce/Assets.xcassets/nvidia-logo.imageset`: the NVIDIA logo, shown next to NVIDIA's models in the model list. NVIDIA owns this trademark.

## Models downloaded in the app

Sotto downloads speech models only when you pick them. Each model keeps its own license.

| Model | Source | License |
|---|---|---|
| Parakeet TDT 0.6B v2 and v3 | [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), Core ML conversion by [FluidInference](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | CC BY 4.0 |
| Parakeet Ultra | [Moondream](https://huggingface.co/moondream/parakeet-ultra), Core ML conversion by [FluidInference](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | CC BY 4.0 |
| Parakeet Unified | [NVIDIA](https://huggingface.co/nvidia/parakeet-unified-en-0.6b), Core ML conversion by FluidInference | CC BY 4.0 |
| Nemotron Latin and Multilingual (streaming) | NVIDIA, Core ML conversion by [FluidInference](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML) | NVIDIA Open Model License or OpenMDW 1.1, see each model card |
| Silero VAD (Core ML) | [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml) | MIT |
| Whisper (ggml) | [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp), from OpenAI's Whisper | MIT |
| Cohere Transcribe | Cohere, GGUF by [handy-computer](https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf) | Apache 2.0 |
| SenseVoice Small | [FunAudioLLM / Alibaba](https://huggingface.co/FunAudioLLM/SenseVoiceSmall), GGUF by handy-computer | [FunASR Model License](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) |
