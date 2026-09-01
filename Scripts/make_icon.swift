// Renders the 1024 × 1024 app icon master (OwlAppIconView) to a PNG.
//
// Usage:
//   swiftc Scripts/make_icon.swift Sources/NightOwl/OwlIconView.swift \
//       -o /tmp/make_icon && /tmp/make_icon /tmp/AppIcon-1024.png
//
// Downscale the master into an .iconset and pack it with
//   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns

import AppKit
import SwiftUI

@main
@MainActor
struct MakeIcon {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write("usage: make_icon <output.png>\n".data(using: .utf8)!)
            exit(2)
        }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

        let renderer = ImageRenderer(content: OwlAppIconView())
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1024, height: 1024)

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(
                "make_icon: failed to render/encode icon\n".data(using: .utf8)!)
            exit(1)
        }

        do {
            try png.write(to: outputURL)
        } catch {
            FileHandle.standardError.write("make_icon: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        print("wrote \(outputURL.path) (\(rep.pixelsWide) × \(rep.pixelsHigh))")
    }
}
