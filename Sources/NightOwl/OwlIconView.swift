import AppKit
import SwiftUI

// MARK: - Vector owl face (no image assets, pure SwiftUI Shape/Path)

/// The owl head: a rounded skull with two pointed ear tufts and a V-shaped
/// dip between them. When awake, two large eye circles are added as subpaths
/// and punched out with an even-odd fill.
struct OwlHeadShape: Shape {
    var isSleeping: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()

        p.move(to: pt(50, 16, rect))                                    // dip between ears
        p.addLine(to: pt(15, 1, rect))                                  // left ear tip
        p.addQuadCurve(to: pt(7, 38, rect), control: pt(9, 13, rect))   // outer edge of left ear
        p.addQuadCurve(to: pt(13, 82, rect), control: pt(6, 74, rect))  // left cheek
        p.addQuadCurve(to: pt(50, 96, rect), control: pt(28, 95, rect)) // bottom left
        p.addQuadCurve(to: pt(87, 82, rect), control: pt(72, 95, rect)) // bottom right
        p.addQuadCurve(to: pt(93, 38, rect), control: pt(91, 74, rect)) // right cheek
        p.addQuadCurve(to: pt(85, 1, rect), control: pt(89, 13, rect))  // outer edge of right ear
        p.closeSubpath()                                                // inner edge back to the dip

        if !isSleeping {
            // Large round "startled" eyes, cut out of the head via even-odd fill.
            p.addEllipse(in: rectFor(16, 28, 32, 32, rect))             // left eye hole
            p.addEllipse(in: rectFor(52, 28, 32, 32, rect))             // right eye hole
        } else {
            // Sleepy closed eyes: thin crescent slits, also punched out.
            p.move(to: pt(20, 43, rect))
            p.addQuadCurve(to: pt(44, 43, rect), control: pt(32, 52, rect))
            p.addQuadCurve(to: pt(20, 43, rect), control: pt(32, 60, rect))
            p.move(to: pt(56, 43, rect))
            p.addQuadCurve(to: pt(80, 43, rect), control: pt(68, 52, rect))
            p.addQuadCurve(to: pt(56, 43, rect), control: pt(68, 60, rect))
        }

        // Diamond beak, punched out like the eyes.
        p.move(to: pt(50, 52, rect))
        p.addLine(to: pt(57, 62, rect))
        p.addLine(to: pt(50, 75, rect))
        p.addLine(to: pt(43, 62, rect))
        p.closeSubpath()
        return p
    }
}

/// Small pupils drawn inside the awake eye holes.
struct OwlPupilsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: rectFor(25.5, 37.5, 13, 13, rect))             // left pupil
        p.addEllipse(in: rectFor(61.5, 37.5, 13, 13, rect))             // right pupil
        return p
    }
}

/// Composite owl face. Shapes carry no color, so the environment foreground
/// style applies (`.black` for menu bar templates, accent colors in-app).
struct OwlIconView: View {
    var isSleeping: Bool

    var body: some View {
        ZStack {
            OwlHeadShape(isSleeping: isSleeping)
                .fill(style: FillStyle(eoFill: true, antialiased: true))
            if !isSleeping {
                OwlPupilsShape()
                    .fill()
            }
        }
    }
}

// MARK: - Menu bar template image

@MainActor
enum OwlMenuBarIcon {
    /// Point size of the menu bar glyph (matches NSStatusItem.squareLength look).
    static let length: CGFloat = 18

    /// Renders the owl face into an `NSImage` flagged as a template, so it
    /// follows the menu bar tint automatically (dark/light/vibrancy).
    static func image(isSleeping: Bool) -> NSImage {
        let view = OwlIconView(isSleeping: isSleeping)
            .frame(width: length, height: length)
            .foregroundStyle(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: length, height: length)
        image.isTemplate = true
        image.accessibilityDescription = isSleeping ? "NightOwl — sleeping" : "NightOwl — keeping awake"
        return image
    }
}

// MARK: - Application (Finder / Dock) icon

/// Full macOS app icon: the wide-awake owl on a night-sky squircle, laid out
/// on the standard 1024 × 1024 canvas. Rendered into Resources/AppIcon.icns
/// by Scripts/make_icon.swift.
struct OwlAppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.17, green: 0.20, blue: 0.36),  // dusk navy
                            Color(red: 0.04, green: 0.06, blue: 0.15)   // midnight
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            OwlIconView(isSleeping: false)
                .frame(width: 520, height: 520)
                .foregroundStyle(Color(red: 1.0, green: 0.79, blue: 0.38))  // moonlit amber
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - Geometry helpers (design space: 100 × 100)

private func pt(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
    let s = min(rect.width, rect.height) / 100
    return CGPoint(x: rect.midX + (x - 50) * s, y: rect.midY + (y - 50) * s)
}

private func rectFor(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rect: CGRect) -> CGRect {
    let s = min(rect.width, rect.height) / 100
    return CGRect(
        x: rect.midX + (x - 50) * s,
        y: rect.midY + (y - 50) * s,
        width: w * s,
        height: h * s
    )
}
