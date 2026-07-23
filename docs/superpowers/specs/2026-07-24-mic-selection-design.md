# Microphone Selection with Per-Device Memory — Design

**Date:** 2026-07-24
**Status:** Approved

## Goal

Let the user choose which microphone Airboard records from, and remember that
choice **per connected hardware situation**. The driving problem: when
Bluetooth earphones connect, macOS switches its default input to the
earphones' mic — which is dramatically worse for ASR (often narrowband
telephony audio) than the MacBook's built-in array — and Airboard blindly
follows, tanking transcription quality. After this feature, the user teaches
Airboard once per headset ("when these are connected, use the MacBook mic")
and never hits the trap again.

## The behavioral model (user-validated, verbatim scenarios)

1. **Mac alone**: the mic list shows only the MacBook microphone; it is used.
   Nothing to configure.
2. **Earphones connect for the FIRST time (no stored rule)**: Airboard follows
   the system default — i.e. the earphones' mic, exactly like today — but the
   popover now lists both mics so the user can change it.
3. **User picks the MacBook mic while the earphones are connected**: Airboard
   stores the rule *"when these earphones are present → MacBook mic"*. The
   choice persists across app restarts, reboots, and reconnects.
4. **Every later time those earphones connect**: the MacBook mic is used
   automatically. No interaction.
5. **A different, never-seen headset connects**: no rule exists for it →
   system default (its own mic), until the user makes a choice for it — which
   is then remembered for that headset independently.

Choosing the earphones' mic (instead of the MacBook's) while they are
connected is equally valid and persists the same way — the memory stores
whatever the user picked, not what we think is best.

## Scope

**In scope**
- `MicDeviceManager` (new): enumerates connected audio *input* devices
  (name, UID, transport type), refreshes live on connect/disconnect, owns the
  per-device rule store, and answers one question: *"which device should this
  recording use right now?"*
- `MicCaptureEngine` (new): shared AVAudioEngine-based capture core that can
  record from a *specific* device (the current `AVAudioRecorder` API cannot),
  producing the same 16kHz mono WAV files the pipeline expects. Used by both
  recorders.
- Refactor `AudioRecorder` and `ChunkedAudioRecorder` onto `MicCaptureEngine`
  with their public interfaces (callbacks, chunk rotation at speech pauses,
  volume normalization, low-latency start) preserved — the coordinator does
  not change.
- Popover: a "Microphone" row (styled like Hotkey/Performance rows) showing
  the currently-resolved mic as its subtitle, with a dropdown of connected
  input mics; picking one stores the rule for the current hardware context.
- Docs + changelog.

**Out of scope (explicitly rejected or deferred)**
- Mic testing / test-by-transcription UI (user chose the simple list).
- "(recommended)" labels or any guidance text in the list.
- Per-application rules, output-device selection, level meters.
- Always-on mic / pre-roll ring buffer (still declined from earlier).
- A rule for the "Mac alone" context (only one mic exists; nothing to store).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Rule keying | `externalDeviceUID → chosenMicUID` map in UserDefaults (`micRuleByDevice`) | The user's model: memory is per external device. Built-in-only context needs no rule. |
| Default when no rule | System default input | Matches today's behavior and the user's scenario 2 (first earphone connect uses earphone mic). No surprises for untaught hardware. |
| Rule creation | Picking any mic while ≥1 external input device is connected stores the rule for that external device | The pick *is* the teaching moment; no separate "remember this" UI. |
| Multiple external devices at once | The most recently connected external device that has a rule wins; ties broken by device UID sort | Deterministic; the case is rare (e.g. USB mic + Bluetooth earphones). |
| Chosen mic missing at record time | Quiet fallback to system default; rule preserved | Never block or nag mid-dictation; the rule resumes when the device returns. |
| Capture API | AVAudioEngine with the input node pinned to a device (HAL audio-unit property) | `AVAudioRecorder` cannot select devices. One shared engine replaces both recorders' capture; chunk rotation and RMS pause detection port over; start latency controllable (prepared engine, mirroring today's pre-prepared-recorder trick). |
| Device identity & names | CoreAudio (`kAudioHardwarePropertyDevices`, device UID / name / transport-type properties); "external" = transport ≠ built-in | UIDs are stable across reconnects; transport type distinguishes built-in from Bluetooth/USB/etc. |
| List freshness | CoreAudio property listener on the device list; popover reflects current devices each time it opens | Earphones connecting while the popover is closed must show up on next open. |

## Architecture

```
AirboardPopover ── "Microphone" row + dropdown
        │ pick(deviceUID)
        ▼
MicDeviceManager ── devices list, rule store, resolveActiveDevice()
        │ deviceID for this recording
        ▼
MicCaptureEngine ── AVAudioEngine pinned to device → 16kHz mono WAV
        ▲                    ▲
AudioRecorder      ChunkedAudioRecorder   (public interfaces unchanged)
        ▲                    ▲
        └── TranscriptionCoordinator (untouched)
```

- `MicDeviceManager.resolveActiveDevice()` runs at every recording start:
  connected externals → check rules (most-recent-with-rule) → resolve chosen
  UID to a present device → else system default. Never cached across
  recordings, so hot-plugs between dictations are always honored.
- `MicCaptureEngine` exposes: `prepare()`, `start(deviceID:to fileURL:)`,
  `rotateFile(to:)` (hands-free chunking), `stop()`, and a published input
  level (RMS) for the existing pause detection. Output format identical to
  today's WAVs.
- `AudioRecorder`/`ChunkedAudioRecorder` keep their names, callbacks, and
  the normalization post-processing; only their capture internals change.

## Failure handling

| Condition | Behavior |
|---|---|
| Chosen device disconnected mid-recording | Engine reports failure → same error path as today's recording failure; next recording resolves afresh (falls back to default) |
| Chosen device absent at start | Silent fallback to system default; rule kept |
| Engine fails to start | Same user-visible error path as today's recorder failure |
| No input devices at all | Same as today (recording fails with error) |

## Documentation

- CLAUDE.md: architecture (capture layer now MicCaptureEngine), new files,
  UserDefaults key `micRuleByDevice`.
- README: feature bullet (choose your mic; remembered per headset).
- CHANGELOG `[Unreleased]`: mic selection with per-device memory; also carries
  the already-committed "AI cleanup subtitle truncation" fix.

## Verification (manual, run by the user — capture layer is high-risk)

1. Mac alone: dictation works; list shows only the MacBook mic.
2. Connect earphones (never taught): dictation uses the earphones mic
   (worse quality expected — proves scenario 2), list shows both.
3. Pick MacBook mic while earphones connected: next dictation is high quality
   (MacBook mic) with earphones still connected and audio still playing
   through them.
4. Disconnect + reconnect earphones, restart the app: MacBook mic still used
   automatically (rule persisted).
5. First words are NOT clipped (hold key, speak immediately) — regression
   check on the rewritten capture layer.
6. Hands-free mode: chunks rotate at pauses, live insertion, correct mic.
7. Command mode unaffected.
8. Popover: AI cleanup subtitle reads "Grammar" untruncated; Microphone row
   subtitle shows the active mic's name.

## Risks

- **Capture-layer rewrite** — the highest-regression-risk change since the
  Parakeet swap; the first-word-latency behavior and hands-free chunk
  rotation must be explicitly re-verified (steps 5–6 above).
- **Bluetooth quality is physics, not a bug**: selecting an earphone mic
  still yields telephony-grade audio on many headsets. The feature's value is
  escaping that, not fixing it.
- **CoreAudio device quirks** (UID stability on some USB hubs, aggregate
  devices): fallback-to-default behavior bounds the damage to "works like
  today."
