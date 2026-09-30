# Voicedic

A local-first Wispr Flow alternative for macOS. A menu bar app: hold **fn**, talk, let go, and the
cleaned-up text is typed into whatever app you're in.

- **Speech-to-text:** NVIDIA Parakeet TDT 0.6B v2 (English) or Parakeet Ultra (25 languages),
  running on the Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).
  About 0.15 s to transcribe 8 s of speech on an M1 Max.
- **Cleanup:** removes filler words and stutters, applies self-corrections ("at 3, no wait, 4"), fixes
  punctuation. Choose one:
  - **Apple on-device** (default): Apple's Foundation Models framework. Local, no download, ~1 s.
  - **Claude Code**: your installed `claude` CLI with Haiku, using your Claude Code login (no API
    key). ~0.8 s. Not local: transcripts go to Anthropic.
  - **Ollama**: any model on your local Ollama server. Use a model of about 4B parameters or more.
  - **Off**: paste the raw transcript.

  If cleanup fails, times out, or returns something that doesn't look like what you said, the raw
  transcript is pasted instead.

The only network access in local mode is the one-time model download from Hugging Face.

## Use

| | |
|---|---|
| Hold **fn** | Record; release to transcribe and insert |
| Double-tap **fn** | Hands-free recording; press **fn** again to finish |
| **Esc** | Cancel recording or processing |

Settings (menu bar icon → Settings…) has the microphone, speech model, cleanup backend, extra instructions,
a vocabulary list for names and jargon, and a local history of dictations. The microphone defaults to
the Mac's built-in one, so connecting AirPods doesn't move dictation onto their mic. Launch at login is on by
default once the app runs from /Applications; turn it off in Settings.

Set **System Settings → Keyboard → Press 🌐 key to → Do Nothing** so the Globe key doesn't also open
the emoji picker or system dictation.

## Build

Requires macOS 26+ on Apple Silicon and Xcode 26+.

```bash
make run       # build build/Voicedic.app, sign it, and open it
make install   # copy to /Applications and open
```

The build script signs with your first "Apple Development" certificate so macOS keeps the
Microphone and Accessibility permissions across rebuilds (`CODESIGN_IDENTITY=-` for ad-hoc).

On first launch, allow **Microphone** and **Accessibility** (needed to read the fn key and to paste).

## Test without the UI

The app binary has a headless mode for checking the pipeline:

```bash
say -o /tmp/test.aiff "um so I was thinking we could meet at three no wait four"
.build/debug/Voicedic --transcribe /tmp/test.aiff --refiner apple
.build/debug/Voicedic --refine "what is the capital of france" --refiner claudeCode --warm 6
```

Options: `--model parakeet-v2|parakeet-ultra`, `--refiner apple|claudeCode|ollama|off`,
`--ollama-model NAME`, `--claude-model NAME`, `--vocab "Term1,Term2"`, `--repeat N`, `--warm SECONDS`.

## Layout

```
Sources/Voicedic/
  VoicedicApp.swift         entry point, menu bar scene
  AppModel.swift            dictation state machine: hotkey → record → transcribe → clean up → paste
  HotkeyMonitor.swift       fn/Esc via a CGEvent tap
  AudioRecorder.swift       microphone capture, levels, resampling to 16 kHz
  Transcriber.swift         Parakeet via FluidAudio
  Refinement/               cleanup prompt, validation, and the three backends
  TextInserter.swift        pasteboard + ⌘V, restoring the previous clipboard
  Overlay.swift             Dynamic Island-style overlay in the notch
  History.swift             local history (~/Library/Application Support/Voicedic)
  Views/                    menu and settings UI
  TestMode.swift            headless --transcribe / --refine
```
