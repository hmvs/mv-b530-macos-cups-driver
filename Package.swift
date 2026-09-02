// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mvb530",
    platforms: [.macOS(.v12)],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .target(name: "MVBProtocol"),
        .target(name: "MVBImage"),
        .target(name: "MVBFilter",
                dependencies: ["CCups", "MVBProtocol", "MVBImage"]),

        // CUPS filter: raster in, printer command stream out.
        .executableTarget(name: "rastertomvb530", dependencies: ["MVBFilter"]),

        // CUPS backend: forwards the stream to the user-session agent.
        .executableTarget(name: "mvb530-backend"),

        // Print agent. The Info.plist is embedded in the binary so it can
        // declare NSBluetoothAlwaysUsageDescription without an .app bundle;
        // without it macOS kills the process the moment it touches Bluetooth.
        .executableTarget(
            name: "mvb530d",
            dependencies: ["MVBProtocol"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/mvb530d/Info.plist",
                ]),
            ]),

        .executableTarget(name: "MVBTests",
                          dependencies: ["MVBProtocol", "MVBImage",
                                         "MVBFilter", "CCups"]),
    ]
)
