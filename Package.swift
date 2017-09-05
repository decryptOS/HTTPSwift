// swift-tools-version:3.1

import PackageDescription

let package = Package(
    name: "HTTPSwift",
    dependencies: [
        .Package(url: "https://github.com/decryptOS/CCurl.git", majorVersion: 1, minor: 0)
    ]
)
