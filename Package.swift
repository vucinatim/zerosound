// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ZeroSound",
  platforms: [
    .macOS("14.2")
  ],
  products: [
    .library(name: "ZeroSoundCore", targets: ["ZeroSoundCore"]),
    .executable(name: "ZeroSound", targets: ["ZeroSoundApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.4")
  ],
  targets: [
    .target(
      name: "ZeroSoundAudioIO",
      path: "Sources/ZeroSoundAudioIO",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("Foundation"),
      ]
    ),
    .target(
      name: "ZeroSoundCore",
      dependencies: ["ZeroSoundAudioIO"],
      linkerSettings: [
        .linkedFramework("AVFAudio"),
        .linkedFramework("Network"),
      ]
    ),
    .executableTarget(
      name: "ZeroSoundApp",
      dependencies: [
        "ZeroSoundCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
    .testTarget(
      name: "ZeroSoundCoreTests",
      dependencies: ["ZeroSoundCore"]
    ),
  ],
  cxxLanguageStandard: .cxx17
)
