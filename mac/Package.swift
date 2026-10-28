// swift-tools-version: 6.0
import PackageDescription

// O app do TrackLab: uma casca SwiftUI sobre o motor Python (`tracklab serve`), com o áudio em AVAudioEngine e a
// partitura numa WKWebView (alphaTab). Construído sem Xcode: `./build.sh` gera build/TrackLab.app. TrackLabCore
// guarda o que não tem interface (modelos da API, mapa de tempo, mixagem, loop), testado por `./test.sh`. Mesma
// estrutura do KaraokeLab e do TabLab, para macOS 15 (o iMac Intel de 2019 não passa do Sequoia).
let package = Package(
    name: "TrackLab",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TrackLabCore", path: "Sources/TrackLabCore"),
        .executableTarget(name: "TrackLab", dependencies: ["TrackLabCore"], path: "Sources/TrackLab"),
        .testTarget(name: "TrackLabCoreTests", dependencies: ["TrackLabCore"], path: "Tests/TrackLabCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
