# Re-speak Last Sentence — Design

Date: 2026-06-05
Status: Approved for v1 implementation

## Problem

The user listens to English audio with AirPods, phone locked in a pocket. When the
speaker talks fast, a sentence flies by and the user misses it. They do **not** want to
unlock the phone and read subtitles — they want to catch it **by ear, hands-free**.

## Solution (v1)

A headphone gesture that, on demand, has the app **re-speak the last sentence clearly**
into the user's ear using on-device text-to-speech, then replay the original sentence.

A steady, unslurred synthetic voice reading the transcribed text is often *more*
intelligible than the original fast speaker, and it requires no network.

### Why fully on-device

The sentence text already exists (the app generates per-sentence subtitle segments).
So the feature only needs:

- `AVSpeechSynthesizer` — on-device TTS, plays through AirPods with the screen locked.
- (future) Apple Translation framework — not in v1.

Result: **no API key, no backend, no cloud, offline-capable, App-Store-shippable with
zero server cost.** This is the path that satisfies the "I want to ship this" requirement.

## Interaction

Trigger: a new headphone action **"Re-speak last sentence"**, assignable to single /
double / triple click in the existing gesture settings. Also exposed as an on-screen
button (parity with the loop button) for in-hand use.

On trigger:

1. Pause the original audio.
2. Find the current/last sentence (`currentSegmentIndex`) and its transcribed text.
3. Speak it via `AVSpeechSynthesizer` (en-US, slightly slowed for clarity).
4. On speech completion: seek to that sentence's start, play the **original** sentence
   once at normal speed, then continue forward normally.

### States (designed up front)

| State | Behavior |
|---|---|
| Normal trigger | pause → speak text → replay original sentence → continue |
| No subtitles for this track | speak a short cue: "No transcript for this part yet." |
| No current sentence (very start / empty) | same spoken cue, no crash |
| Triggered again while speaking | cancel current speech, resume (acts as interrupt) |
| On-screen (unlocked) | show "🔊 Re-speaking…" indicator, highlight the sentence |

## Architecture

- `SpeechReader.swift` *(new)* — wraps `AVSpeechSynthesizer`; `speak(_ text:, rate:,
  onFinish:)` and `stop()`. Keeps TTS out of the large view-model. `@Published isSpeaking`.
- `ButtonAction` — add `.speakLastSentence` case (displayName, Codable, in `allCases`),
  so it appears in the gesture pickers automatically.
- `PlayerViewModel` — owns a `SpeechReader`; `speakLastSentence()` orchestrates the flow
  above; `executeAction` routes the new case. Publishes speaking state for the UI.
- `PlayerView` — on-screen button + speaking indicator.
- `SettingsView` — no change (pickers read `ButtonAction.allCases`).

## Known v1 limitations (explicit, out of scope)

- Reads the **transcribed** text, so accuracy is bounded by subtitle quality (user
  reports these are "mostly correct"). If fast-speech transcription is ever insufficient,
  the future upgrade is **cloud transcription (Whisper / gpt-4o-transcribe)** — which
  requires the backend and is therefore explicitly **not** in v1.
- "Last sentence" = the segment currently/just playing when the click lands. If the user
  reacts slowly and the next segment already started, they get that one. Acceptable for v1.
- Voice rate is a fixed slightly-slow constant in v1; may become a user setting later.

## Non-goals

- No pronunciation/connected-speech tutoring.
- No Chinese translation in v1 (English re-speak only).
- No cloud, no backend, no subscription in v1.
