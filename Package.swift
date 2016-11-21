import PackageDescription

let package = Package(
    name: "GeneratedSwiftServer",
    dependencies: [
        .Package(url: "https://github.com/IBM-Swift/Kitura.git", majorVersion: 1),
    ]
)
