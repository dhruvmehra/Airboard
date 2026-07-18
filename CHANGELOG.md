# Changelog

All notable changes to Airboard are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

New changes go under **[Unreleased]** as you work. Running `./build_release.sh`
promotes that section to the released version automatically.

## [Unreleased]

### Changed
- Rebranded from Murmur to Airboard
- Fixed dropped words and a stuck-transcribing bug
- Debug builds are now clearly separated from the released app (own name and bundle ID in macOS permission settings)
- Swapped the speech engine from Whisper large-v3-turbo (WhisperKit) to NVIDIA Parakeet TDT 0.6B v3 (FluidAudio): better English accuracy and ~10× faster transcription. Requires Apple Silicon.

### Removed
- Experimental Flan-T5 grammar correction (quality didn't justify the complexity)
- Unused self-correction detector code
- Custom vocabulary feature (its mechanism was Whisper-specific; superseded by a future LLM cleanup stage)

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
