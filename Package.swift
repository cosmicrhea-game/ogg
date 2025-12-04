// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ogg",

  products: [
    .library(name: "Ogg", targets: ["Ogg"]),
    .library(name: "COgg", targets: ["COgg"]),
  ],

  targets: [
    .target(
      name: "COgg",
      path: ".",
      sources: ["src/bitwise.c", "src/framing.c"],
      publicHeadersPath: "include",
    ),

    .target(
      name: "Ogg",
      dependencies: ["COgg"],
      path: "swift",
    ),
  ]
)
