// swift-tools-version:5.9
import PackageDescription

// The app's rule logic, compiled on its own so it can be tested on a Mac and in
// CI without the Xcode project or the private algorithms submodule. Sources/
// holds symlinks to the app's files; it never has code of its own. A file
// added here must stay free of UIKit, MapKit, WatchKit and Supabase.
let package = Package(
    name: "AppLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AppLogic"),
        .testTarget(name: "AppLogicTests", dependencies: ["AppLogic"]),
    ]
)
