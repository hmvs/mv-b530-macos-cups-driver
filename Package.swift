// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mvb530",
    platforms: [.macOS(.v13)],
    targets: [
        // PAPPL is vendored and built by scripts/build-pappl.sh: it is not
        // packaged for Homebrew.
        .systemLibrary(name: "CPAPPL", path: "Sources/CPAPPL"),

        // Non-variadic wrappers: Swift cannot call C variadic functions.
        .target(name: "CPAPPLSupport",
                cSettings: [.unsafeFlags(["-Ivendor/pappl"])]),

        .target(name: "MVBProtocol"),
        .target(name: "MVBImage"),
        .target(name: "MVBTransport",
                // For the packet decoder: the printer's flow-control
                // notifications arrive in the same framing it is sent.
                dependencies: ["MVBProtocol"],
                linkerSettings: [.linkedFramework("CoreBluetooth")]),

        // The whole driver: an IPP Everywhere printer application that talks
        // BLE to the hardware itself.
        .executableTarget(
            name: "mvb530-printer-app",
            dependencies: ["CPAPPL", "CPAPPLSupport", "MVBProtocol",
                           "MVBImage", "MVBTransport"],
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
                          dependencies: ["MVBProtocol", "MVBImage"]),
    ]
)
