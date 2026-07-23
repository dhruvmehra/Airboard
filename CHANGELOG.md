# Changelog

All notable changes to Airboard are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

New changes go under **[Unreleased]** as you work. Running `./build_release.sh`
promotes that section to the released version automatically.

## [Unreleased]

## [1.0.5] - 2026-07-24

### Fixed
- Released builds could not access the microphone (no permission prompt, no entry in System Settings): the release pipeline's re-signing step was stripping the app's entitlements. Affected 1.0.2–1.0.4; the pipeline now verifies entitlements and signature instead of re-signing

## [1.0.4] - 2026-07-24

### Added
- MIT LICENSE file (the README already claimed MIT; now it's true)
- Automatic updates (Sparkle): the app checks at launch and daily, downloads in the background, and installs on quit. "Check for Updates" available in the menu popover

### Changed
- AI cleanup now runs on dictations of 6+ words (was 12) — fast providers like Cerebras made the round-trip imperceptible
- Performance metrics measure transcription time only, no longer including the AI cleanup round-trip

## [1.0.3] - 2026-07-19

### Added
- Filler-word removal ("um", "uh", "ah") in all dictation modes — local, always on
- Optional AI cleanup via any OpenAI-compatible endpoint (OpenRouter, AWS Bedrock, Ollama, vLLM): grammar and punctuation fixes, paragraph breaks, spoken enumerations formatted as bullet or numbered lists. Configured in the menu popover; API key stored in the Keychain; falls back to local rules within 4s if the server is slow or unreachable; short dictations (under 12 words) skip the server entirely and insert instantly

### Changed
- Rebranded from Murmur to Airboard
- Fixed dropped words and a stuck-transcribing bug
- Debug builds are now clearly separated from the released app (own name and bundle ID in macOS permission settings)
- Swapped the speech engine from Whisper large-v3-turbo (WhisperKit) to NVIDIA Parakeet TDT 0.6B v3 (FluidAudio): better English accuracy and ~10× faster transcription. Requires Apple Silicon.

### Removed
- Experimental Flan-T5 grammar correction (quality didn't justify the complexity)
- Unused self-correction detector code
- Custom vocabulary feature (its mechanism was Whisper-specific; superseded by the AI cleanup stage above)

## [1.0.2] - 2025-12-30

### Added
- Onboarding flow with simplified permission setup
- Custom vocabulary for names and jargon
- Audio normalization for better recognition
- Feedback reporting ("Report issue")

## [1.0.0] - 2025-12-02

Initial release: hold-hotkey dictation with fully local Whisper transcription,
voice commands (hold + ⌘), hands-free mode (double-tap), context-aware
insertion via the Accessibility API.
