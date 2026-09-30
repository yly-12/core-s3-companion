#!/usr/bin/env swift

import Foundation

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

private let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let repositoryRoot = scriptDirectory
  .deletingLastPathComponent()
  .deletingLastPathComponent()
private let m5gfxRoot = repositoryRoot
  .appendingPathComponent("firmware/CoreS3Companion/.pio/libdeps/m5stack-cores3/M5GFX/src/lgfx")

private func read(_ url: URL) -> String {
  guard let value = try? String(contentsOf: url, encoding: .utf8) else {
    fail("cannot read \(url.path)")
  }
  return value
}

private func parseHexArray(_ source: String) -> [UInt8] {
  guard let opening = source.range(of: "static const unsigned char font[] PROGMEM = {") else {
    fail("Font0 array was not found")
  }
  guard let closing = source.range(of: "};", range: opening.upperBound..<source.endIndex) else {
    fail("Font0 array is not terminated")
  }
  let body = source[opening.upperBound..<closing.lowerBound]
  let expression = try! NSRegularExpression(pattern: #"0x([0-9A-Fa-f]{2})"#)
  let nsBody = String(body) as NSString
  return expression.matches(in: String(body), range: NSRange(location: 0, length: nsBody.length)).map {
    UInt8(nsBody.substring(with: $0.range(at: 1)), radix: 16)!
  }
}

private func parseCStringArray(_ source: String, named name: String) -> [UInt8] {
  guard let declaration = source.range(of: "const uint8_t \(name)[") else {
    fail("\(name) was not found")
  }
  guard let equals = source.range(of: "=", range: declaration.upperBound..<source.endIndex) else {
    fail("\(name) is malformed")
  }

  let scalars = Array(source[equals.upperBound...].unicodeScalars)
  var bytes: [UInt8] = []
  var inString = false
  var index = 0

  while index < scalars.count {
    let scalar = scalars[index]
    if !inString {
      if scalar == ";" { break }
      if scalar == "\"" { inString = true }
      index += 1
      continue
    }
    if scalar == "\"" {
      inString = false
      index += 1
      continue
    }
    if scalar != "\\" {
      guard scalar.value <= 0x7f else { fail("non-ASCII byte in \(name)") }
      bytes.append(UInt8(scalar.value))
      index += 1
      continue
    }

    index += 1
    guard index < scalars.count else { fail("unfinished escape in \(name)") }
    let escaped = scalars[index]
    if escaped.value >= 48 && escaped.value <= 55 {
      var value = 0
      var digits = 0
      while index < scalars.count, digits < 3 {
        let candidate = scalars[index].value
        guard candidate >= 48 && candidate <= 55 else { break }
        value = value * 8 + Int(candidate - 48)
        digits += 1
        index += 1
      }
      bytes.append(UInt8(truncatingIfNeeded: value))
      continue
    }

    let escapedBytes: [UnicodeScalar: UInt8] = [
      "\\": 92, "\"": 34, "'": 39, "n": 10, "r": 13, "t": 9,
      "a": 7, "b": 8, "f": 12, "v": 11, "?": 63,
    ]
    guard let value = escapedBytes[escaped] else {
      fail("unsupported escape \\(escaped) in \(name)")
    }
    bytes.append(value)
    index += 1
  }
  return bytes
}

private struct BitReader {
  let bytes: [UInt8]
  var byteIndex: Int
  var bitIndex = 0

  mutating func unsigned(_ count: Int) -> Int {
    var result = 0
    for outputBit in 0..<count {
      guard byteIndex < bytes.count else { fail("U8g2 bit reader exceeded font data") }
      let bit = (bytes[byteIndex] >> bitIndex) & 1
      result |= Int(bit) << outputBit
      bitIndex += 1
      if bitIndex == 8 {
        bitIndex = 0
        byteIndex += 1
      }
    }
    return result
  }

  mutating func signed(_ count: Int) -> Int {
    unsigned(count) - (1 << (count - 1))
  }
}

private struct U8gGlyph {
  let width: Int
  let height: Int
  let xOffset: Int
  let yOffset: Int
  let advance: Int
  let pixels: [Bool]
}

private struct U8gFont {
  let bytes: [UInt8]

  private var maxHeight: Int { Int(Int8(bitPattern: bytes[10])) }
  private var fontYOffset: Int { Int(Int8(bitPattern: bytes[12])) }
  private var metricsYOffset: Int { -(maxHeight + fontYOffset) }

  private func glyphDataOffset(for encoding: Int) -> Int? {
    var cursor = 23
    if encoding >= 97 {
      cursor += Int(bytes[19]) << 8 | Int(bytes[20])
    } else if encoding >= 65 {
      cursor += Int(bytes[17]) << 8 | Int(bytes[18])
    }
    while cursor + 1 < bytes.count, bytes[cursor + 1] != 0 {
      if Int(bytes[cursor]) == encoding { return cursor + 2 }
      cursor += Int(bytes[cursor + 1])
    }
    return nil
  }

  func glyph(for scalar: UnicodeScalar) -> U8gGlyph? {
    guard scalar.value <= 255,
          let dataOffset = glyphDataOffset(for: Int(scalar.value)) else { return nil }
    var reader = BitReader(bytes: bytes, byteIndex: dataOffset)
    let width = reader.unsigned(Int(bytes[4]))
    let height = reader.unsigned(Int(bytes[5]))
    let xOffset = reader.signed(Int(bytes[6]))
    let glyphY = reader.signed(Int(bytes[7]))
    let advance = reader.signed(Int(bytes[8]))
    let yOffset = -(glyphY + height + metricsYOffset)
    var pixels = [Bool](repeating: false, count: width * height)
    var x = 0
    var y = 0

    func consume(_ count: Int, value: Bool, x: inout Int, y: inout Int,
                 pixels: inout [Bool]) {
      var remaining = count
      while remaining > 0, y < height {
        let length = min(remaining, width - x)
        if value, length > 0 {
          for column in x..<(x + length) {
            let pixelIndex = y * width + column
            guard pixelIndex >= 0, pixelIndex < pixels.count else {
              fail("U8g2 glyph pixel index \(pixelIndex) is outside \(pixels.count)")
            }
            pixels[pixelIndex] = true
          }
        }
        remaining -= length
        x += length
        if x == width { x = 0; y += 1 }
      }
    }

    while y < height {
      let zeroRun = reader.unsigned(Int(bytes[2]))
      let oneRun = reader.unsigned(Int(bytes[3]))
      var repeatPair = true
      while repeatPair, y < height {
        consume(zeroRun, value: false, x: &x, y: &y, pixels: &pixels)
        consume(oneRun, value: true, x: &x, y: &y, pixels: &pixels)
        repeatPair = y < height && reader.unsigned(1) != 0
      }
    }
    return U8gGlyph(width: width, height: height, xOffset: xOffset,
                    yOffset: yOffset, advance: advance, pixels: pixels)
  }
}

private struct SVGBuilder {
  let font0: [UInt8]
  let titleFont: U8gFont
  var elements: [String] = []

  mutating func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int,
                     _ color: String) {
    guard width > 0, height > 0 else { return }
    elements.append(#"<rect x="\#(x)" y="\#(y)" width="\#(width)" height="\#(height)" fill="\#(color)"/>"#)
  }

  mutating func outline(_ x: Int, _ y: Int, _ width: Int, _ height: Int,
                        _ color: String) {
    rect(x, y, width, 1, color)
    rect(x, y + height - 1, width, 1, color)
    rect(x, y + 1, 1, height - 2, color)
    rect(x + width - 1, y + 1, 1, height - 2, color)
  }

  func font0Width(_ text: String, scale: Int) -> Int {
    text.utf8.count * 6 * scale
  }

  mutating func font0Text(_ text: String, x: Int, y: Int, scale: Int,
                          color: String, align: String = "left") {
    let width = font0Width(text, scale: scale)
    let isCentered = align == "center" || align == "middle-center"
    let startX = align == "right" ? x - width : (isCentered ? x - width / 2 : x)
    let startY = align == "middle-center" ? y - 4 * scale : y
    for (characterIndex, code) in text.utf8.enumerated() {
      let glyphStart = Int(code) * 5
      guard glyphStart + 4 < font0.count else { continue }
      for row in 0..<8 {
        var column = 0
        while column < 5 {
          while column < 5 && (font0[glyphStart + column] & (1 << row)) == 0 { column += 1 }
          let runStart = column
          while column < 5 && (font0[glyphStart + column] & (1 << row)) != 0 { column += 1 }
          if column > runStart {
            rect(startX + characterIndex * 6 * scale + runStart * scale,
                 startY + row * scale, (column - runStart) * scale, scale, color)
          }
        }
      }
    }
  }

  mutating func titleText(_ text: String, x: Int, y: Int, color: String) {
    var cursor = x
    for scalar in text.unicodeScalars {
      guard let glyph = titleFont.glyph(for: scalar) else { continue }
      for row in 0..<glyph.height {
        var column = 0
        while column < glyph.width {
          while column < glyph.width && !glyph.pixels[row * glyph.width + column] { column += 1 }
          let runStart = column
          while column < glyph.width && glyph.pixels[row * glyph.width + column] { column += 1 }
          if column > runStart {
            rect(cursor + glyph.xOffset + runStart, y + glyph.yOffset + row,
                 column - runStart, 1, color)
          }
        }
      }
      cursor += glyph.advance
    }
  }
}

private struct Preview {
  let filename: String
  let accessibleTitle: String
  let profile: String
  let profileColor: String
  let battery: String
  let batteryColor: String
  let title: String
  let state: String
  let stateColor: String
  let sourceSVG: String
  let metrics: [(label: String, reset: String, value: Int, barColor: String)]
  let model: String
  let effort: String
}

private let glcdSource = read(m5gfxRoot.appendingPathComponent("Fonts/glcdfont.h"))
private let efontSource = read(m5gfxRoot.appendingPathComponent("Fonts/efont/lgfx_efont_cn.c"))
private let font0 = parseHexArray(glcdSource)
private let titleFontBytes = parseCStringArray(efontSource, named: "lgfx_efont_cn_16_b")
private let titleFont = U8gFont(bytes: titleFontBytes)

guard font0.count == 1280 else { fail("Font0 has \(font0.count) bytes, expected 1280") }
guard titleFontBytes.count >= 320_445 else {
  fail("efontCN_16_b has only \(titleFontBytes.count) decoded bytes")
}

private let previews = [
  Preview(
    filename: "12-pixel-accurate-personal.svg",
    accessibleTitle: "Pixel-accurate Codex Personal main screen",
    profile: "PERSONAL", profileColor: "#58A6FF",
    battery: "BAT 83%", batteryColor: "#46F59A",
    title: "CORES3 PROFILE SUPPORT", state: "RUNNING", stateColor: "#46F59A",
    sourceSVG: "10-dual-profile-personal.svg",
    metrics: [("5H 68%", "2H14m", 68, "#46F59A"),
              ("WK 42%", "3D8H", 42, "#46F59A"),
              ("CTX 61%", "SESSION", 61, "#FFC857")],
    model: "GPT-6-ASTRA", effort: "EFF HIGH"),
  Preview(
    filename: "13-pixel-accurate-work.svg",
    accessibleTitle: "Pixel-accurate Codex Work main screen",
    profile: "WORK", profileColor: "#C084FC",
    battery: "BAT 82%", batteryColor: "#F2F5F3",
    title: "RELEASE WORKFLOW REVIEW", state: "AUTH", stateColor: "#FFC857",
    sourceSVG: "11-dual-profile-work.svg",
    metrics: [("5H 31%", "48m", 31, "#FFC857"),
              ("WK 78%", "5D2H", 78, "#46F59A"),
              ("CTX 44%", "SESSION", 44, "#FFC857")],
    model: "GPT-6-SOL", effort: "EFF XHIGH"),
]

private func embeddedImage(from filename: String) -> String {
  let source = read(scriptDirectory.appendingPathComponent(filename))
  guard let start = source.range(of: "href=\"data:image/png;base64,"),
        let end = source.range(of: "\"", range: start.upperBound..<source.endIndex) else {
    fail("embedded animation was not found in \(filename)")
  }
  return "data:image/png;base64," + String(source[start.upperBound..<end.lowerBound])
}

for preview in previews {
  var svg = SVGBuilder(font0: font0, titleFont: titleFont)
  svg.rect(0, 0, 320, 240, "#000000")

  // Header proposal: profile centered on the 320 px screen; no active counter.
  svg.font0Text("CODEX", x: 16, y: 11, scale: 2, color: "#10A37F")
  svg.outline(133, 7, 54, 20, preview.profileColor)
  svg.font0Text(preview.profile, x: 160, y: 17, scale: 1,
                color: preview.profileColor, align: "middle-center")
  svg.font0Text(preview.battery, x: 304, y: 11, scale: 2,
                color: preview.batteryColor, align: "right")
  svg.rect(16, 34, 288, 1, "#173128")

  svg.titleText(preview.title, x: 16, y: 43, color: "#F2F5F3")
  svg.rect(16, 76, 8, 50, preview.stateColor)
  svg.font0Text(preview.state, x: 40, y: 80, scale: 5, color: preview.stateColor)
  svg.elements.append(#"<image x="256" y="77" width="48" height="48" href="\#(embeddedImage(from: preview.sourceSVG))" style="image-rendering:pixelated"/>"#)

  svg.rect(16, 144, 288, 1, "#173128")
  let metricX = [16, 117, 218]
  for (index, metric) in preview.metrics.enumerated() {
    let x = metricX[index]
    svg.font0Text(metric.label, x: x, y: 158, scale: 2, color: "#F2F5F3")
    svg.rect(x, 178, 86, 6, "#173128")
    svg.rect(x, 178, metric.value * 86 / 100, 6, metric.barColor)
    svg.font0Text(metric.reset, x: x, y: 190, scale: 2, color: "#7C8782")
  }
  svg.font0Text(preview.model, x: 16, y: 218, scale: 2, color: "#F2F5F3")
  svg.font0Text(preview.effort, x: 304, y: 218, scale: 2,
                color: "#7C8782", align: "right")

  let document = """
  <svg xmlns="http://www.w3.org/2000/svg" width="320" height="240" viewBox="0 0 320 240" role="img" aria-labelledby="title desc" shape-rendering="crispEdges">
    <title id="title">\(preview.accessibleTitle)</title>
    <desc id="desc">320 by 240 proposed framebuffer preview using the exact M5GFX Font0 and efontCN_16_b bitmap glyphs used by the firmware.</desc>
    \(svg.elements.joined(separator: "\n  "))
  </svg>
  """
  do {
    try document.write(to: scriptDirectory.appendingPathComponent(preview.filename),
                       atomically: true, encoding: .utf8)
    print("generated \(preview.filename)")
  } catch {
    fail("cannot write \(preview.filename): \(error)")
  }
}
