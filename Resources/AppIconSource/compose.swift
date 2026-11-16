import AppKit

// Usage: compose <body.png> <fg.png> <out.png> <pixelSize>
// Draws the icon body with a soft drop shadow, then the foreground glyphs with their own lift shadow.
let args = CommandLine.arguments
guard args.count == 5, let size = Int(args[4]) else {
    FileHandle.standardError.write("usage: compose <body.png> <fg.png> <out.png> <size>\n".data(using: .utf8)!)
    exit(2)
}
func cgImage(_ path: String) -> CGImage {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot load \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return cg
}
let body = cgImage(args[1])
let fg = cgImage(args[2])

let s = CGFloat(size) / 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let shadowInk = CGColor(srgbRed: 11/255, green: 8/255, blue: 48/255, alpha: 1)

// 1. Body with macOS-style ambient drop shadow (CG y-axis points up, so negative height = downward).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: shadowInk.copy(alpha: 0.40))
ctx.draw(body, in: rect)
ctx.restoreGState()

// 2. Glyphs: a wide soft lift shadow plus a tight contact shadow for depth.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 36 * s, color: shadowInk.copy(alpha: 0.55))
ctx.draw(fg, in: rect)
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4 * s), blur: 6 * s, color: shadowInk.copy(alpha: 0.35))
ctx.draw(fg, in: rect)
ctx.restoreGState()

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3]) \(size)px")
