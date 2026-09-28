# Local screenshot → Ollama → macOS overlay

A native Swift implementation for **macOS 14+**, using the clipboard, ImageIO,
URLSession, and AppKit. It is intended for your Apple Silicon Mac and the exact
model `qwen3.5:27b-mlx`. There are **no third-party library dependencies**.

## Source and launch

- `OllamaScreenOverlay.swift`: complete application source.
- `run.sh`: compiles a small app bundle once, signs it locally, and launches it.
- `Tests.swift` and `test.sh`: automated regression checks and optional live vision test.

The launcher rebuilds after source changes. Build products live in `.build/`;
screenshots and responses are never saved there. No Xcode project is needed.

## Installation

Install Apple's Command Line Tools if you don't already have `swiftc`:

```sh
xcode-select --install
```

Install the current macOS Ollama application from
[Ollama's official download](https://ollama.com/download/mac) if needed. With an
existing Homebrew installation, the equivalent command is:

```sh
brew install --cask ollama-app
```

Start Ollama and download the model:

```sh
open -a Ollama
ollama pull qwen3.5:27b-mlx
```

Alternatively, start `ollama serve` in a separate terminal and leave it running.
Use the app **or** `ollama serve`; only one server can listen on port 11434.
There is no need to start a second server if Ollama is already running.
Model installation downloads weights; screenshot analysis uses only the local server.

**Verified on your Mac (2026-09-28):** Ollama `0.34.4` with the installed
`qwen3.5:27b-mlx` passed the live image-reading test. An earlier `0.20.7`
installation failed that check. The app checks actual image input before
submitting your first clipboard screenshot and explains any failure. It keeps
your requested model and never silently switches to another one.

If the check fails after a runtime change, update Ollama from its official
download (or `brew upgrade --cask ollama-app` for a Homebrew installation), restart
the server, re-run `ollama pull qwen3.5:27b-mlx`, and run `./run.sh --check`.

## Run

From this folder:

```sh
chmod +x run.sh test.sh
./run.sh --check
./run.sh
```

The app starts quietly with a small menu-bar icon. Waiting, checks, and analysis
stay hidden; the overlay appears only when an answer is ready. It does not capture
your display or send a request to Ollama on startup. Take a screenshot **to the clipboard**:

- **Control–Command–Shift–4 (⌃⌘⇧4):** select an area or press Space to choose a window.
- **Control–Command–Shift–3 (⌃⌘⇧3):** capture the whole screen.

Keep Control held while taking the screenshot. The app receives the clipboard
image, checks Ollama on the first submission, analyzes the image, and displays
the answer. It keeps listening so you can take another screenshot without
restarting. Screenshots observed during inference are queued and processed in
order. The previous answer hides when a new image is received, and the overlay
stays hidden while processing the queue. The last completed answer remains visible.

The clipboard's existing image at startup is ignored. Text and copied file paths
are ignored. **Any newly copied image** is treated as a submission, including
images copied from other apps. The app reads but never clears or replaces your
clipboard. A clipboard holds only its latest contents: an image replaced before
the next poll (every 250 ms) cannot be recovered. Screenshot shortcuts without
Control normally save a file, which this app does not watch.

The app does not need Screen Recording or Accessibility permission because
macOS takes the screenshot and the app reads the resulting clipboard image.
If macOS asks whether the app may read/paste from other apps, allow that access.
The selected area or screen comes from your screenshot; the location of the
terminal used to start the script has no effect. The overlay itself can appear
in full-screen screenshots, so keep it outside the area you select.

To customize the analysis:

```sh
./run.sh --prompt 'Read and summarize the visible text. Be concise.'
./run.sh --timeout 600 --max-tokens 4096
```

For all options:

```sh
./run.sh --help
```

The overlay appears near the top-right of the primary display without taking
keyboard focus. Only the answer text is visible: the borderless window is fully
transparent, with no title bar, background, buttons, status labels, or scrollbars.
It uses a 12-point white system font with a small dark text shadow for contrast. Text
wraps; the panel grows up to 480 points wide and 380 points tall, additionally
capped at 40% of the usable display width/height. Longer responses scroll without
being removed; use the mouse wheel or trackpad over the text to scroll.
Text can be selected and copied.

Use the menu-bar icon to see status/errors, **Hide answer** while keeping the
listener active, or **Quit Ollama Screen Overlay**. **Escape** also quits after you
click the answer. Quitting during inference cancels the client request and exits;
the server may take a moment to notice the disconnect. The terminal's launch
command returns once the app closes. Errors appear in the menu, keeping the overlay
reserved for answers; `--check` reports errors to stderr and exits nonzero.

## How it works

1. `ClipboardScreenshotSource` records `NSPasteboard.general.changeCount` at startup,
   then checks for changes every 250 ms. It accepts new PNG, TIFF, JPEG, or HEIC
   image data and retries briefly if the clipboard provider has not supplied the
   promised data yet. It never takes a screenshot itself.
2. On the first screenshot, `OllamaClient` queries `GET /api/version` and `POST /api/show`. It rejects a
   missing model, incompatible version, missing capability metadata, a model
   without `vision`, and remote/cloud model metadata. It then sends a generated
   five-digit number image to verify actual image input. The expected digits
   appear only in the image, never in the prompt. This additional local request
   catches builds that advertise vision but silently ignore images.
   A successful check is reused for subsequent screenshots in the same run.
3. `ScreenshotImage` validates that the clipboard image is complete. It keeps PNG
   bytes unchanged and converts other supported image formats to PNG in memory.
4. `POST http://127.0.0.1:11434/api/chat` carries the PNG bytes as a base64 string
   inside the user message's `images` array, alongside your prompt. It sends
   `stream: false` and `think: false`, and waits for a finished assistant message.
5. `OverlayController` shows that message verbatim as plain, multiline text in
   a transparent, borderless floating `NSPanel`. `NSScrollView` handles overflow
   without visible scrollbars. The panel joins Spaces
   and uses the full-screen auxiliary window behavior.

Image decoding/PNG encoding and JSON/network work run outside the main UI actor.
Window updates and clipboard reads run on the main actor. Listening continues
while waiting for inference. Network requests have cancellation and a total deadline, including
model-loading time. The inference deadline defaults to five minutes.

The app uses an ephemeral URLSession without a disk cache, disables proxies,
fixes the API destination to loopback, and refuses HTTP redirects. It does not
read `OLLAMA_HOST`, use an external API, save screenshots, or log model answers.
Ollama itself controls its own in-memory caches and server logging.

## Failure handling and compatibility

Connection failures explain how to start Ollama. Missing-model errors include
the pull command. Clipboard/image errors ask you to take another screenshot.
API errors preserve the server's diagnostic message. Malformed JSON, incomplete
messages, and empty/whitespace-only answers are errors; a thinking-only response
is not treated as an answer. A token-limited answer remains visible with a
truncation notice in the menu-bar menu.

Missing capability metadata stops submission with an update instruction. A
runtime image/vision/projector error is reported explicitly even when model
metadata advertises vision; there is no retry that silently drops the image.
The image self-check runs both in the app and with `--check`. An incorrect read
stops that screenshot submission with a diagnosis; the listener stays active so
you can fix Ollama and take another screenshot. This is a practical compatibility
check, not a proof of image understanding: OCR mistakes can also cause failure,
and a passing check does not guarantee every screenshot answer is correct.

macOS controls what content is included in the screenshots you take.
The overlay sits above normal app windows and supports full-screen
Spaces, but it cannot override macOS security dialogs or every exclusive app's
window policy. These are macOS restrictions.

## Verification

```sh
./test.sh          # Private test clipboard, image decoding, and mock HTTP; no screen access
./test.sh --live   # Same real image check used by the app; no screenshot
./run.sh --demo    # Preview multiline wrapping/scrolling; no capture or API request
```

The live test generates a fresh five-digit number in an in-memory PNG and asks
the requested model to read it. The number is absent from the textual prompt.
It exits nonzero if the returned digits do not match. For debugging the test
image itself, `./test.sh --live --save-probe` explicitly saves that synthetic
image to `.build/vision-probe.png`; normal app use never writes image files.

Clipboard tests use an isolated, named pasteboard and leave your clipboard
untouched. They cover startup images, new/repeated screenshots, text/file copies,
delayed image data, TIFF conversion, and recovery after unavailable image data.
All **63 regression checks** passed after the transparent overlay update, and the
signed app was rebuilt and restarted. UI automation timed out, so the updated
appearance has not been visually verified. Earlier, `./run.sh --check --timeout 60`
passed with local Ollama `0.34.4` and `qwen3.5:27b-mlx`. The real macOS screenshot
shortcut through to the final answer was not exercised during this verification.

## API references

- [Apple screenshot shortcuts and copying to the clipboard](https://support.apple.com/en-gb/102646)
- [Apple clipboard change count](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
- [Ollama image submission format](https://docs.ollama.com/capabilities/vision)
- [Ollama model capability metadata](https://docs.ollama.com/api-reference/show-model-details)
- [Ollama macOS setup](https://docs.ollama.com/macos)
# OllamaScreenOverlay
