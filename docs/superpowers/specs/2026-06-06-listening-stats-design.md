# Listening Stats Card — Design

Date: 2026-06-06
Status: Built (v1)

## Goal

A glanceable signal that the user has been showing up. Two numbers, top of the Library
tab, every time they open the app:

- **TODAY** — minutes listened today
- **TOTAL** — minutes listened all-time

No streak counter, no chart. Honest and ungameable.

## Visual

Editorial big-number typography wrapped in a bordered material card:

- Card: `.regularMaterial` fill, 16pt continuous corner radius, hairline `.separator`
  border, 16pt horizontal margin from screen edges
- Labels (`TODAY` / `TOTAL`): `.caption2`, letter-spaced, `.secondary`
- Numbers: ~52pt, `.thin`, rounded design, monospaced digits (no dancing as values bump)
- Unit (`min`): `.caption`, `.secondary`, under each number
- Middle: a single ultralight `·` divider, vertically aligned with the numbers
- **Zero state:** when `TODAY == 0`, that column dims to ~30% opacity so the eye glides
  past to `TOTAL`

Works light and dark mode out of the box via material + hierarchical styles.

## Counting rule

"Anything you hear in the app counts" (user choice). Specifically:

- **Main player playing** → 0.25s credited per playback-timer tick. Includes the AI
  slow-loop wait (still real audio in the user's ears).
- **AI explanation voice playing** → credited on completion / cancel / track-switch
  using `Date()` delta between start and stop.
- **Paused** → nothing counted.

## Data + persistence (`ListeningStats.swift`)

- Storage: `UserDefaults`
  - `stats_total_seconds_v1` (Double) — lifetime total
  - `stats_day_seconds_v1` (Data → `[String: Double]`) — per-day map keyed by
    `yyyy-MM-dd` in **device local time**
- `@Published todayMinutes` / `@Published totalMinutes` — whole-minute Ints, republished
  only when the minute count actually changes (no 0.25s UI churn)
- `record(seconds:)` — accumulates raw seconds, persists every ~30s (120 ticks)
- `flush()` — synchronous write; called on pause path, app background, and terminate
  (via the same lifecycle observers that already protect progress persistence)

## Edge cases

- **Cross-midnight playback:** each `record` re-reads today's key from device local time,
  so seconds after midnight land in the new day's bucket. The TODAY value automatically
  resets to 0 at midnight if the user keeps listening; the previous day's tally stays in
  the lifetime total.
- **Time-zone change while traveling:** uses current device local day. Simple and honest.
- **Crash before next 30s flush:** loses ≤30s — acceptable for this metric.
- **Headphone disconnect** already auto-pauses → main timer stops → counting stops.

## Observation wiring caveat

`vm.stats` is a nested `ObservableObject`; SwiftUI doesn't propagate its `@Published`
changes through the outer view-model. Wrapped the card in a tiny `StatsCardContainer`
that holds `@ObservedObject var stats: ListeningStats` so the minute-bumps actually
re-render the UI.

## Non-goals (v1)

- No streak counter (user explicitly asked for "only both" numbers)
- No daily chart, no per-track breakdown
- No iCloud sync (single-device)
- No reset button (could add to Settings later if requested)
