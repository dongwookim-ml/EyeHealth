// Generates the EyeHealth app icon: a bloodshot eye on a rounded-rect
// background. Deterministic (seeded PRNG), so re-runs produce the same image.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

// Seeded LCG so vein placement is reproducible.
var seed: UInt64 = 20260712
func rnd() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 11) / Double(UInt64(1) << 53)
}
func rnd(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * rnd() }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: rounded rect with a soft vertical gradient.
let bgRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
           ending: NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.90, alpha: 1))!
    .draw(in: bgPath, angle: -90)

// Almond-shaped eye.
let left = NSPoint(x: 152, y: 512)
let right = NSPoint(x: 872, y: 512)
let eye = NSBezierPath()
eye.move(to: left)
eye.curve(to: right, controlPoint1: NSPoint(x: 300, y: 812), controlPoint2: NSPoint(x: 724, y: 812))
eye.curve(to: left, controlPoint1: NSPoint(x: 724, y: 212), controlPoint2: NSPoint(x: 300, y: 212))
eye.close()

NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.97, alpha: 1).setFill()
eye.fill()

// Everything inside the eye is clipped to it.
NSGraphicsContext.current!.saveGraphicsState()
eye.addClip()

// Irritated pink shading toward the edges of the sclera.
NSGradient(starting: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0),
           ending: NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.40, alpha: 0.35))!
    .draw(in: eye, relativeCenterPosition: .zero)

// Bloodshot veins radiating from both corners toward the iris.
let center = NSPoint(x: 512, y: 512)
let irisR = 170.0
let veinColor = { (a: Double) in NSColor(calibratedRed: 0.75, green: 0.10, blue: 0.08, alpha: a) }
for (corner, dir) in [(left, 1.0), (right, -1.0)] {
    for _ in 0..<9 {
        let endAngle = rnd(-0.9, 0.9) // fan spread, radians around horizontal
        let stop = irisR + rnd(15, 90) // stop short of / near the iris
        let end = NSPoint(x: center.x - dir * stop * cos(endAngle),
                          y: center.y + stop * sin(endAngle) * 1.1)
        let start = NSPoint(x: corner.x + dir * rnd(0, 30), y: corner.y + rnd(-40, 40))
        let midX = (start.x + end.x) / 2
        let c1 = NSPoint(x: midX + rnd(-50, 50), y: start.y + rnd(-80, 80))
        let c2 = NSPoint(x: midX + rnd(-50, 50), y: end.y + rnd(-80, 80))

        let vein = NSBezierPath()
        vein.move(to: start)
        vein.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        vein.lineWidth = rnd(5, 12)
        vein.lineCapStyle = .round
        veinColor(rnd(0.45, 0.8)).setStroke()
        vein.stroke()

        // Occasional short branch from the midpoint.
        if rnd() < 0.5 {
            let branch = NSBezierPath()
            let bStart = NSPoint(x: midX, y: (start.y + end.y) / 2 + rnd(-30, 30))
            branch.move(to: bStart)
            branch.curve(to: NSPoint(x: bStart.x + dir * rnd(40, 110), y: bStart.y + rnd(-90, 90)),
                         controlPoint1: NSPoint(x: bStart.x + dir * rnd(10, 50), y: bStart.y + rnd(-40, 40)),
                         controlPoint2: NSPoint(x: bStart.x + dir * rnd(20, 80), y: bStart.y + rnd(-60, 60)))
            branch.lineWidth = rnd(3, 6)
            branch.lineCapStyle = .round
            veinColor(rnd(0.35, 0.6)).setStroke()
            branch.stroke()
        }
    }
}

// Hazel iris with a radial gradient and a dark rim.
let irisRect = NSRect(x: center.x - irisR, y: center.y - irisR, width: irisR * 2, height: irisR * 2)
let iris = NSBezierPath(ovalIn: irisRect)
NSGradient(starting: NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.28, alpha: 1),
           ending: NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.07, alpha: 1))!
    .draw(in: iris, relativeCenterPosition: NSPoint(x: -0.15, y: 0.15))
NSColor(calibratedRed: 0.22, green: 0.13, blue: 0.05, alpha: 1).setStroke()
iris.lineWidth = 10
iris.stroke()

// Pupil.
let pupilR = 72.0
NSColor.black.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - pupilR, y: center.y - pupilR,
                            width: pupilR * 2, height: pupilR * 2)).fill()

// Highlights.
NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
NSBezierPath(ovalIn: NSRect(x: 430, y: 560, width: 60, height: 60)).fill()
NSColor(calibratedWhite: 1, alpha: 0.5).setFill()
NSBezierPath(ovalIn: NSRect(x: 560, y: 440, width: 28, height: 28)).fill()

NSGraphicsContext.current!.restoreGraphicsState()

// Eye outline on top.
NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.15, alpha: 1).setStroke()
eye.lineWidth = 16
eye.lineJoinStyle = .round
eye.stroke()

NSGraphicsContext.current!.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
