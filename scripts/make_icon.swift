import AppKit
import CoreText

// Rosemartin by Eko Bimantara. Rendered artwork only; the font is not installed globally.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let dir = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let provider = CGDataProvider(url:root.appendingPathComponent("Fonts/Rosemartin/Rosemartin-3lpDM.otf") as CFURL)!
let font = CTFontCreateWithGraphicsFont(CGFont(provider)!, 600, nil, nil)
var characters: [UniChar] = [89, 65]
var glyphs = [CGGlyph](repeating:0,count:2)
CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 2)
var advances = [CGSize](repeating:.zero,count:2)
CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, 2)
let rawLetters = CGMutablePath()
var x: CGFloat = 0
for i in 0..<2 {
    let t = CGAffineTransform(translationX:x,y:0)
    rawLetters.addPath(CTFontCreatePathForGlyph(font,glyphs[i],nil)!,transform:t)
    x += advances[i].width - 28
}
let bounds = rawLetters.boundingBoxOfPath
let scale = min(690/bounds.width, 530/bounds.height)
let letterTransform = CGAffineTransform(a:scale,b:0,c:0,d:scale,
    tx:512-bounds.midX*scale,ty:512-bounds.midY*scale)
let letters = CGMutablePath()
letters.addPath(rawLetters,transform:letterTransform)
func render(_ n: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:n, pixelsHigh:n,
        bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false,
        colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(n)/1024); transform.concat()
    let tile = NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896), xRadius:200,yRadius:200)
    NSGradient(starting:NSColor(white:0.10,alpha:1), ending:NSColor(white:0.16,alpha:1))!.draw(in:tile,angle:90)
    tile.addClip()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.setShadow(offset:CGSize(width:0,height:-7),blur:11,color:CGColor(gray:0,alpha:0.45))
    ctx.addPath(letters); ctx.setFillColor(CGColor(gray:0.78,alpha:1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(letters); ctx.clip()
    let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),
        colors:[CGColor(gray:0.68,alpha:1), CGColor(gray:0.87,alpha:1), CGColor(gray:0.98,alpha:1)] as CFArray,
        locations:[0,0.58,1])!
    ctx.drawLinearGradient(gradient,start:CGPoint(x:512,y:240),end:CGPoint(x:512,y:790),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(letters); ctx.clip()
    ctx.translateBy(x:0,y:-1.2)
    ctx.addPath(letters); ctx.setStrokeColor(CGColor(gray:1,alpha:0.65)); ctx.setLineWidth(2.4); ctx.strokePath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
try render(1024).write(to:root.appendingPathComponent("AppIcon-YA.png"))
for base in [16,32,128,256,512] { for scale in [1,2] {
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try render(base*scale).write(to:dir.appendingPathComponent(name))
}}
// ICNS uses PNG payloads for modern macOS icon representations.
var body=Data()
for (tag,file) in [("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png"),("ic11","icon_16x16@2x.png"),("ic12","icon_32x32@2x.png"),("ic13","icon_128x128@2x.png"),("ic14","icon_256x256@2x.png")] {
 let data=try Data(contentsOf:dir.appendingPathComponent(file));body.append(Data(tag.utf8));var length=UInt32(data.count+8).bigEndian;body.append(Data(bytes:&length,count:4));body.append(data)
}
var result=Data("icns".utf8);var length=UInt32(body.count+8).bigEndian;result.append(Data(bytes:&length,count:4));result.append(body)
try result.write(to:root.appendingPathComponent("AppIcon.icns"))
