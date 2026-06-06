# AI Audio-In Explain — Design

Date: 2026-06-06
Status: Built (v1, BYO-key, pre-App-Store)

## Problem

Listening with AirPods, phone locked. A fast sentence flies by and the user can't make
out the words. They want help understanding *this* sentence — what was actually said.

(Supersedes the earlier "re-speak last sentence" TTS design, which was dropped: reading
the transcript back didn't help with genuinely fast/slurred speech.)

## Solution (v1)

Send the **actual audio** of the current sentence to a multimodal model that *listens*
and explains it, then plays the explanation as voice. Audio-in is the point: the model
hears what this speaker actually did, not a generic textbook rule.

- Model: OpenAI `gpt-4o-audio-preview`, Chat Completions, `modalities: ["text","audio"]`.
  One round trip returns both a written explanation and a spoken (mp3) version.
- Explanation: clear simple English describing what's said + which parts are
  reduced/linked, ending with one short Chinese summary sentence.

### Deployment (v1 vs later)

- **v1 (now):** BYO key. User enters Base URL + API key + model in Settings; the app calls
  the provider directly. Pre-App-Store only.
- **Later:** ship requires a backend proxy (holds key, meters usage). Code is structured so
  this is a **Base URL change** — all request-building lives in `AIExplainer`.

## Interaction

Trigger: on-screen ✨ button on the player, and an assignable headphone action
(`ButtonAction.aiExplain`). Target = the current sentence (`currentSegmentIndex`).

Flow:
1. Press → pause original audio.
2. Start a **0.6× slow-loop** of the sentence so the user keeps listening during the wait
   (uses the existing sentence-loop machinery). Screen-on: a sheet shows "AI is listening…".
3. Extract a small **WAV** clip of the sentence (`AVAudioFile`, with ~0.15s/0.4s padding)
   and POST it.
4. On reply: wait for the next loop boundary (so a word isn't cut), then play the AI's
   spoken explanation. Sheet shows the text.
5. When the voice finishes → replay the original sentence once at normal speed → continue.

### States

| State | Ears | Screen |
|---|---|---|
| preparing / waiting | sentence slow-loops at 0.6× | spinner + "AI is listening…" + Cancel |
| speaking | AI voice plays the explanation | explanation text (scrollable) |
| error | spoken "the AI didn't respond" + resume sentence | error message + Retry |
| not configured | spoken "AI is not set up yet" | error asking to set key in Settings |
| no transcript | spoken "No transcript here" | error |

Press again at any stage = **cancel** (release request, restore rate, resume playback).
Cache by model + sentence text → re-pressing the same sentence is instant and free.

## Architecture

- `AIExplainer.swift` *(new)* — `AIConfig` (persisted), `AIExplainState`, `AIExplanation`,
  the network call, response parsing, in-memory cache, cancel, and a `/models`
  connectivity test. Pure: no playback, no view-model dependency.
- `PlayerViewModel` — owns `AIExplainer`; `aiExplain()` / `cancelAI()` orchestrate
  pause → slow-loop → extract → request → play-at-boundary → resume. Clip extraction
  (`extractClip`, WAV via `AVAudioFile`) lives here since it owns the file + security
  scope. A separate `AVAudioPlayer` plays the returned mp3; a small `AVSpeechSynthesizer`
  speaks error cues.
- `ButtonAction.aiExplain` — appears in the gesture pickers automatically.
- `SettingsView` — "AI 听力解析" section: Base URL, API key, model, Test connection.
- `PlayerView` — ✨ button + `AIExplainSheet`.

## Known limitations / risks (explicit)

- **Request shape** depends on the current `gpt-4o-audio-preview` API. If field names
  differ in practice, only `AIExplainer.makeRequest`/`parse` need adjusting.
- **Untested against the live model** (no key available here). Code builds; flow validated
  by reasoning. User must drop in a key and confirm on device.
- **Clip size:** WAV at source sample rate (no downsampling yet) → a few-second stereo clip
  can be ~1–2 MB base64. Fine on Wi-Fi; a downsample-to-16k-mono pass is a future optimization.
- **0.6× via AVAudioPlayer** sounds a bit robotic but stays intelligible; tunable.
- Cost: ~$0.01–0.03 per uncached press at current prices.

## Non-goals (v1)

- No backend / no subscription / no metering.
- No pronunciation scoring or per-word tap-to-hear.
