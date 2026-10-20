import AppKit
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let original=NSImage(contentsOf:root.appendingPathComponent("AppIcon-liquid-glass.png"))!
let dir=root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
for base in [16,32,128,256,512] {for scale in [1,2] {
 let n=base*scale
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:n,pixelsHigh:n,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
 NSGraphicsContext.current?.imageInterpolation = .high
 original.draw(in:NSRect(x:0,y:0,width:n,height:n),from:.zero,operation:.copy,fraction:1)
 NSGraphicsContext.restoreGraphicsState()
 let name="icon_\(base)x\(base)\(scale==2 ? "@2x":"").png"
 try bitmap.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name))
}}
// ICNS uses PNG payloads for modern macOS icon representations.
var body=Data()
for (tag,file) in [("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png"),("ic11","icon_16x16@2x.png"),("ic12","icon_32x32@2x.png"),("ic13","icon_128x128@2x.png"),("ic14","icon_256x256@2x.png")] {
 let data=try Data(contentsOf:dir.appendingPathComponent(file));body.append(Data(tag.utf8));var length=UInt32(data.count+8).bigEndian;body.append(Data(bytes:&length,count:4));body.append(data)
}
var result=Data("icns".utf8);var length=UInt32(body.count+8).bigEndian;result.append(Data(bytes:&length,count:4));result.append(body)
try result.write(to:root.appendingPathComponent("AppIcon.icns"))
