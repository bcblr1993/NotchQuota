import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(srgbRed: 0.07, green: 0.075, blue: 0.085, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 218, y: 552, width: 588, height: 255), xRadius: 75, yRadius: 75).fill()
NSColor(srgbRed: 0.07, green: 0.075, blue: 0.085, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 339, y: 652, width: 346, height: 155), xRadius: 45, yRadius: 45).fill()
let colors = [NSColor(srgbRed: 0.38, green: 0.86, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.95, green: 0.78, blue: 0.37, alpha: 1), NSColor(srgbRed: 1, green: 0.44, blue: 0.48, alpha: 1)]
for i in 0..<3 { colors[i].setFill(); NSBezierPath(roundedRect: NSRect(x: 224 + i * 210, y: 276, width: 156, height: 94 + i * 26), xRadius: 28, yRadius: 28).fill() }
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
