// Usage: probe a.wav b.wav …  → prints "filename<TAB>transcript" per file.
// Same model/config as ParakeetTranscriptionService (v3, .default config,
// fresh TdtDecoderState per file). A file that fails prints "<ERROR>".
import Foundation
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v3)
let m = AsrManager(config: .default)
try await m.loadModels(models)
for path in CommandLine.arguments.dropFirst() {
    var st = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
    let name = (path as NSString).lastPathComponent
    do {
        let r = try await m.transcribe(URL(fileURLWithPath: path), decoderState: &st)
        print("\(name)\t\(r.text.trimmingCharacters(in: .whitespacesAndNewlines))")
    } catch {
        print("\(name)\t<ERROR>")
    }
}
