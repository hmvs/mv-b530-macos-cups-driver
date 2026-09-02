// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mvb530",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .systemLibrary(name: "CPAPPL", path: "Sources/CPAPPL"),
        // Non-variadic wrappers: Swift cannot call C variadic functions.
        .target(name: "CPAPPLSupport",
                cSettings: [.unsafeFlags(["-Ivendor/pappl"])]),
        .target(name: "MVBProtocol"),
        .target(name: "MVBImage"),
        .target(name: "MVBTransport",
                linkerSettings: [.linkedFramework("CoreBluetooth")]),
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
            dependencies: ["MVBProtocol", "MVBTransport"],
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

        // IPP Everywhere printer application: replaces the filter, the
        // backend and the agent with one user-session process.
        .executableTarget(
            name: "mvb530-printer-app",
            dependencies: ["CPAPPL", "CPAPPLSupport", "MVBProtocol",
                           "MVBImage"],
            exclude: ["Info.plist"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-Ivendor/pappl"])],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                // PAPPL's macOS build puts a status item in the menu bar.
                .linkedFramework("AppKit"),
                .unsafeFlags([
                    "-Lvendor/pappl/pappl", "-lpappl",
                    "-L/opt/homebrew/opt/openssl@3/lib", "-lssl", "-lcrypto",
                    "-lcups", "-lz", "-lpam",
                    // Declares NSBluetoothAlwaysUsageDescription without an
                    // .app bundle; without it macOS kills the process on the
                    // first CoreBluetooth call.
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/mvb530-printer-app/Info.plist",
                ]),
            ]),

        .executableTarget(name: "MVBTests",
                          dependencies: ["MVBProtocol", "MVBImage",
                                         "MVBFilter", "CCups"]),
    ]
)
