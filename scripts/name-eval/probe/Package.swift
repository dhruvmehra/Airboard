// swift-tools-version:5.9
// Parakeet probe for scripts/name-eval/gen.sh: transcribes WAV files with the
// same model and config the app uses (FluidAudio 0.15.5, Parakeet TDT v3,
// AsrManager(config: .default), fresh decoder state per file).
import PackageDescription
let package = Package(name: "probe", platforms: [.macOS(.v14)],
  dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")],
  targets: [.executableTarget(name: "probe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])])
