# Murmur 🎤

A lightweight macOS voice transcription app that converts speech to text using OpenAI's Whisper API. Press a hotkey, speak, and watch your words appear instantly in any application.

## Features

- **🎯 Hotkey Activated**: Hold Right Option key to record, release to transcribe
- **🤖 AI-Powered**: Uses OpenAI Whisper API for accurate transcription
- **📱 Context-Aware**: Adjusts formatting based on active app (email, messaging, code, etc.)
- **⚡️ Fast & Lightweight**: Minimal UI with floating indicator
- **✨ Auto-Insert**: Transcribed text appears directly where you're typing
- **🔒 Privacy-Focused**: Runs locally, only sends audio to OpenAI for transcription

## Demo

https://github.com/user-attachments/assets/your-demo-video.mov

## Requirements

- macOS 13.0 or later
- OpenAI API key
- Microphone access
- Accessibility permissions

## Installation

### From Source

1. Clone the repository:
```bash
git clone https://github.com/YOUR_USERNAME/murmur.git
cd murmur
```

2. Create `murmur/Config.swift` with your OpenAI API key:
```swift
import Foundation

struct Config {
    static let openAIAPIKey = "your-openai-api-key-here"
}
```

3. Open `murmur.xcodeproj` in Xcode

4. Build and run (Cmd+R)

5. Grant permissions when prompted:
   - **Microphone**: Click "OK"
   - **Accessibility**: Open System Settings and enable

## Usage

1. Press and hold **Right Option** (⌥) key
2. Speak your message
3. Release the key
4. Watch the text appear!

### Visual Feedback

- 🔴 **Red microphone**: Recording
- 🟠 **Orange waveform**: Transcribing
- Text automatically inserts into your active app

## Context-Aware Formatting

Murmur detects your active application and adjusts formatting:

- **Email clients**: Professional format with proper structure
- **Messaging apps**: Casual, conversational tone
- **Code editors**: Code-friendly formatting
- **Documents**: Professional prose with proper grammar
- **Browsers**: Adapts to context (search vs. forms)

## Configuration

### Change Hotkey

Edit `HotkeyManager.swift`:

```swift
private let targetKeyCode: UInt16 = 58 // Right Option
// Options: 58 = Right Option, 61 = Left Option, 59 = Right Control
```

### Adjust Audio Quality

Edit `AudioRecorder.swift`:

```swift
let settings = [
    AVSampleRateKey: 16000,  // Increase for better quality (e.g., 44100)
    AVNumberOfChannelsKey: 1,
    // ... other settings
]
```

## Project Structure

```
murmur/
├── murmur/
│   ├── murmurApp.swift           # Main app and permission handling
│   ├── HotkeyManager.swift       # Hotkey detection
│   ├── AudioRecorder.swift       # Audio recording
│   ├── TranscriptionService.swift # Whisper API integration
│   ├── TextInserter.swift        # Text insertion via accessibility
│   ├── FloatingWindowManager.swift # Visual indicator
│   ├── AppContextDetector.swift  # Active app detection
│   ├── Config.swift              # API key (gitignored)
│   ├── Info.plist               # Permissions
│   └── murmur.entitlements      # Security entitlements
├── README.md
├── PERMISSION_SETUP.md
└── UPDATES_SUMMARY.md
```

## Permissions

### Microphone
Required to record audio for transcription.

### Accessibility
Required to insert transcribed text into other applications.

Both permissions are requested automatically on first launch.

## Troubleshooting

### Hotkey not working
- Check Console for "🎤 Starting hotkey monitoring"
- Ensure app is running (check Activity Monitor)

### No indicator appears
- Grant Accessibility permission in System Settings
- Check Console for error messages

### Text not inserting
- Enable Accessibility in System Settings > Privacy & Security > Accessibility
- Click into a text field before recording

### Poor transcription quality
- Speak clearly near microphone
- Reduce background noise
- Consider increasing sample rate in AudioRecorder.swift

## Privacy & Security

- Audio is sent to OpenAI's servers for transcription
- No audio is stored permanently
- API key is stored locally (not in git repo)
- Temporary audio files are saved to Documents directory

## Roadmap

- [ ] Custom vocabulary/glossary support
- [ ] Multiple language support
- [ ] Offline transcription option
- [ ] Recording history
- [ ] Edit-before-insert mode
- [ ] Customizable hotkeys via UI
- [ ] Menu bar settings panel

## Contributing

Contributions are welcome! Please open an issue or submit a PR.

## License

MIT License - see LICENSE file for details

## Acknowledgments

- Built with [OpenAI Whisper API](https://platform.openai.com/docs/guides/speech-to-text)
- Inspired by Wispr Flow

## Support

Having issues? Check out:
- [Permission Setup Guide](PERMISSION_SETUP.md)
- [Updates Summary](UPDATES_SUMMARY.md)
- [GitHub Issues](https://github.com/YOUR_USERNAME/murmur/issues)

---

Made with ❤️ by [Your Name]
