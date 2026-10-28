// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeFlight",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodeFlight", targets: ["CodeFlightApp"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1")],
    targets: [
        .executableTarget(name: "CodeFlightApp", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "CodeFlightAppTests", dependencies: ["CodeFlightApp"])
    ]
)
