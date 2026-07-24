//
//  DesignSystem.swift
//
//  Airboard design system v2 "Sleek Dark" tokens, translated once from
//  .claude/skills/airboard-design/tokens/*.css. Styled views consume these
//  constants — never raw hex or ad-hoc Color.x.opacity() literals. The app
//  is dark-only (forced .darkAqua at launch); there are no light variants
//  by design.
//

import SwiftUI

enum DS {

    // MARK: Surfaces
    enum Surface {
        static let window  = Color(hex: 0x0F0F11)
        static let panel   = Color(hex: 0x161618)
        static let control = Color(hex: 0x1D1D20)
        static let hud       = Color(.sRGB, red: 24/255, green: 24/255, blue: 28/255, opacity: 0.78)
        static let hudBorder = Color.white.opacity(0.10)
    }

    // MARK: Labels
    enum Label {
        static let primary    = Color.white.opacity(0.92)
        static let secondary  = Color.white.opacity(0.55)
        static let tertiary   = Color.white.opacity(0.28)
        static let quaternary = Color.white.opacity(0.10)
        static let onAccent   = Color.white
    }

    // MARK: Fills
    enum Fill {
        static let hover      = Color.white.opacity(0.05)
        static let quaternary = Color.white.opacity(0.06)
        static let tertiary   = Color.white.opacity(0.08)
        static let secondary  = Color.white.opacity(0.12)
        static let track      = Color.white.opacity(0.14)
    }

    // MARK: Apple system palette (dark-appearance vivid values)
    enum Palette {
        static let red    = Color(hex: 0xFF453A)
        static let orange = Color(hex: 0xFF9F0A)
        static let green  = Color(hex: 0x30D158)
        static let cyan   = Color(hex: 0x64D2FF)
        static let blue   = Color(hex: 0x0A84FF)
        static let indigo = Color(hex: 0x5E5CE6)
        static let purple = Color(hex: 0xBF5AF2)
    }

    // MARK: Semantic accents
    enum Accent {
        static let primary      = Palette.blue    // every default CTA + selection
        static let recording    = Palette.red     // the ONLY UI use of red
        static let transcribing = Palette.orange
        static let command      = Palette.purple
        static let download     = Palette.blue
        static let success      = Palette.green
        static let warning      = Palette.orange
    }

    // MARK: Tinted badges (accent @16% behind a vivid glyph)
    enum Tint {
        static let red    = Palette.red.opacity(0.16)
        static let orange = Palette.orange.opacity(0.16)
        static let green  = Palette.green.opacity(0.16)
        static let blue   = Palette.blue.opacity(0.16)
        static let purple = Palette.purple.opacity(0.16)
        static let cardOrange = Palette.orange.opacity(0.10)
        static let cardGreen  = Palette.green.opacity(0.10)
        static let cardBlue   = Palette.blue.opacity(0.09)
    }

    // MARK: Borders
    enum Border {
        static let hairline = Color.white.opacity(0.08)
        static let control  = Color.white.opacity(0.14)
        static let selected = Palette.blue.opacity(0.55)
    }

    // MARK: Spacing scale
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
    }

    // MARK: Radii
    enum Radius {
        static let r3: CGFloat = 3
        static let r5: CGFloat = 5
        static let r8: CGFloat = 8
        static let r10: CGFloat = 10
        static let r12: CGFloat = 12
        static let r16: CGFloat = 16
        static let full: CGFloat = 999
    }

    // MARK: Badge geometry
    enum Badge {
        static let size: CGFloat = 32
        static let glyph: CGFloat = 14
    }

    // MARK: Typography
    enum Typo {
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
    }
}

extension Color {
    /// 0xRRGGBB initializer for DS token values.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    /// AppKit mirrors for window chrome (NSWindow.backgroundColor).
    static let dsSurfaceWindow = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x11/255, alpha: 1)
    static let dsSurfacePanel  = NSColor(srgbRed: 0x16/255, green: 0x16/255, blue: 0x18/255, alpha: 1)
}
