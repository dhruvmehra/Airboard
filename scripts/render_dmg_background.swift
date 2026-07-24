//
//  render_dmg_background.swift
//
//  Renders the DMG installer background per the design system's approved
//  reference (.claude/skills/airboard-design/ui_kits/airboard-app/
//  dmg-installer.html): dark radial surface, brand header with version,
//  two drop-zone rings joined by a blue arrow, instruction line, privacy
//  footer. The rings are EMPTY — the real Airboard.app and Applications
//  icons sit on them (Finder draws icons and labels).
//
//  Usage: swift render_dmg_background.swift <version> <app-icns> <outdir>
//  Writes bg.png (678×420) and bg@2x.png (1356×840) into <outdir>.
//

import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: render_dmg_background.swift <version> <app-icns> <outdir>")
    exit(1)
}
let version = args[1]
let iconPath = args[2]
let outDir = URL(fileURLWithPath: args[3], isDirectory: true)

let W: CGFloat = 678, H: CGFloat = 420

func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let tx = rgba(244, 244, 246, 1)
let tx2 = rgba(244, 244, 246, 0.56)
let tx3 = rgba(244, 244, 246, 0.32)
let blue = rgba(10, 132, 255, 1)
let green = rgba(48, 209, 88, 1)

// Design coordinates are top-left; AppKit draws bottom-left.
func fromTop(_ yTop: CGFloat, _ height: CGFloat) -> CGFloat { H - yTop - height }

func drawCentered(_ text: NSAttributedString, centerX: CGFloat, topY: CGFloat) {
    let size = text.size()
    text.draw(at: NSPoint(x: centerX - size.width / 2, y: fromTop(topY, size.height)))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Base + top radial wash (#1b1b1f → #121214 on #111113)
    rgba(0x11, 0x11, 0x13, 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    NSGradient(starting: rgba(0x1B, 0x1B, 0x1F, 1), ending: rgba(0x12, 0x12, 0x14, 1))?
        .draw(fromCenter: NSPoint(x: W / 2, y: H + 84), radius: 0,
              toCenter: NSPoint(x: W / 2, y: H + 84), radius: 470,
              options: [.drawsAfterEndingLocation])
    // Faint blue glow rising from the bottom edge
    NSGradient(starting: rgba(10, 132, 255, 0.08), ending: rgba(10, 132, 255, 0))?
        .draw(fromCenter: NSPoint(x: W / 2, y: -34), radius: 0,
              toCenter: NSPoint(x: W / 2, y: -34), radius: 210, options: [])

    // Brand header: icon (red glow) + name + version
    if let icon = NSImage(contentsOfFile: iconPath) {
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = rgba(255, 69, 58, 0.35)
        glow.shadowBlurRadius = 14
        glow.set()
        icon.draw(in: NSRect(x: W / 2 - 20, y: fromTop(26, 40), width: 40, height: 40))
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    drawCentered(NSAttributedString(string: "Airboard", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: tx, .kern: -0.25,
    ]), centerX: W / 2, topY: 76)
    drawCentered(NSAttributedString(string: "VERSION \(version)", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
        .foregroundColor: tx3, .kern: 0.84,
    ]), centerX: W / 2, topY: 103)

    // Drop-zone rings (empty — Finder's icons land on them).
    // Row layout from the reference: zone(150) 56 arrow(64) 56 zone(150),
    // centered → ring centers x=176 and x=502, y=209 (top coords).
    func ring(centerX: CGFloat, dashed: Bool) {
        let rect = NSRect(x: centerX - 59, y: fromTop(150, 118), width: 118, height: 118)
        let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
        rgba(255, 255, 255, 0.045).setFill()
        path.fill()
        path.lineWidth = 1.5
        if dashed {
            path.setLineDash([6, 6], count: 2, phase: 0)
            rgba(255, 255, 255, 0.16).setStroke()
        } else {
            rgba(255, 255, 255, 0.10).setStroke()
        }
        path.stroke()
    }
    ring(centerX: 176, dashed: false)  // Airboard.app zone
    ring(centerX: 502, dashed: true)   // Applications zone

    // Label plates: Finder draws icon labels in BLACK on background-picture
    // DMG windows regardless of system appearance (verified in dark mode),
    // so the labels need a light surface under them or they vanish into
    // the dark art. Plates sit exactly where Finder places labels for
    // 84pt icons centered at y=209.
    func labelPlate(centerX: CGFloat, width: CGFloat) {
        let rect = NSRect(x: centerX - width / 2, y: fromTop(253, 20), width: width, height: 20)
        rgba(233, 234, 238, 0.88).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }
    labelPlate(centerX: 176, width: 82)    // "Airboard"
    labelPlate(centerX: 502, width: 108)   // "Applications"

    // Blue arrow between the zones (center 339, 209 top coords)
    NSGraphicsContext.current?.saveGraphicsState()
    let arrowGlow = NSShadow()
    arrowGlow.shadowColor = rgba(10, 132, 255, 0.35)
    arrowGlow.shadowBlurRadius = 12
    arrowGlow.set()
    let arrowY = fromTop(209, 0)
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 309, y: arrowY))
    arrow.line(to: NSPoint(x: 361, y: arrowY))
    arrow.move(to: NSPoint(x: 351, y: arrowY + 8))
    arrow.line(to: NSPoint(x: 361, y: arrowY))
    arrow.line(to: NSPoint(x: 351, y: arrowY - 8))
    blue.setStroke()
    arrow.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Instruction: "Drag Airboard into Applications to install"
    let instr = NSMutableAttributedString()
    func plain(_ s: String) { instr.append(NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: tx2])) }
    func strong(_ s: String) { instr.append(NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: tx])) }
    plain("Drag "); strong("Airboard"); plain(" into "); strong("Applications"); plain(" to install")
    let instrSize = instr.size()
    instr.draw(at: NSPoint(x: W / 2 - instrSize.width / 2, y: 52))

    // Footer: green dot + privacy statline
    let foot = NSAttributedString(string: "ON-DEVICE SPEECH TO TEXT · OPTIONAL AI CLEANUP", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
        .foregroundColor: tx3, .kern: 0.63,
    ])
    let footSize = foot.size()
    let footX = W / 2 - (footSize.width + 13) / 2
    NSGraphicsContext.current?.saveGraphicsState()
    let dotGlow = NSShadow()
    dotGlow.shadowColor = green
    dotGlow.shadowBlurRadius = 6
    dotGlow.set()
    green.setFill()
    NSBezierPath(ovalIn: NSRect(x: footX, y: 22 + footSize.height / 2 - 2.5, width: 5, height: 5)).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    foot.draw(at: NSPoint(x: footX + 13, y: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(CGFloat(1), "bg.png"), (CGFloat(2), "bg@2x.png")] {
    let rep = render(scale: scale)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("❌ PNG encode failed for \(name)"); exit(1)
    }
    try png.write(to: outDir.appendingPathComponent(name))
}
print("✅ DMG background rendered (678×420 @1x/@2x) for version \(version)")
