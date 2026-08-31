#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let frameCount = 4
private let outputSize = 48
private let outputInset = 2

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
  exit(1)
}

guard CommandLine.arguments.count == 6 else {
  fail("usage: build_status_gifs.swift STRIP.png FRAMES_DIR OUTPUT.gif FRAME_DELAY_SECONDS NAME")
}

let stripURL = URL(fileURLWithPath: CommandLine.arguments[1])
let framesURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let gifURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let frameDelay = Double(CommandLine.arguments[4]), frameDelay > 0 else {
  fail("frame delay must be positive")
}
let name = CommandLine.arguments[5]

guard let source = CGImageSourceCreateWithURL(stripURL as CFURL, nil),
      let input = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
  fail("cannot read \(stripURL.path)")
}

let width = input.width
let height = input.height
let nominalCellWidth = width / frameCount
guard nominalCellWidth > 0 else { fail("strip is too narrow") }

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
guard let readContext = CGContext(
  data: &pixels,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: bytesPerRow,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fail("cannot create source bitmap context")
}

// Normalize PNG coordinates into a top-to-bottom pixel buffer.
readContext.translateBy(x: 0, y: CGFloat(height))
readContext.scaleBy(x: 1, y: -1)
readContext.interpolationQuality = .none
readContext.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let normalized = readContext.makeImage() else {
  fail("cannot normalize source image")
}

func cellRange(_ index: Int) -> Range<Int> {
  let lower = index * nominalCellWidth
  let upper = index == frameCount - 1 ? width : (index + 1) * nominalCellWidth
  return lower..<upper
}

func alphaBounds(in cell: Int) -> CGRect? {
  let range = cellRange(cell)
  var minX = range.count
  var minY = height
  var maxX = -1
  var maxY = -1

  for y in 0..<height {
    for globalX in range {
      let alpha = pixels[y * bytesPerRow + globalX * 4 + 3]
      if alpha > 8 {
        let localX = globalX - range.lowerBound
        minX = min(minX, localX)
        minY = min(minY, y)
        maxX = max(maxX, localX)
        maxY = max(maxY, y)
      }
    }
  }

  guard maxX >= minX, maxY >= minY else { return nil }
  return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let bounds = (0..<frameCount).compactMap(alphaBounds)
guard bounds.count == frameCount else {
  fail("one or more cells contain no visible pixels")
}

var union = bounds[0]
for box in bounds.dropFirst() {
  union = union.union(box)
}

// Keep a small shared source-space margin so all frames retain identical anchors.
let margin = max(2, Int(ceil(max(union.width, union.height) * 0.025)))
let maxCellWidth = (0..<frameCount).map { cellRange($0).count }.min()!
let cropX = max(0, Int(floor(union.minX)) - margin)
let cropY = max(0, Int(floor(union.minY)) - margin)
let cropMaxX = min(maxCellWidth, Int(ceil(union.maxX)) + margin)
let cropMaxY = min(height, Int(ceil(union.maxY)) + margin)
let cropWidth = cropMaxX - cropX
let cropHeight = cropMaxY - cropY
guard cropWidth > 0, cropHeight > 0 else { fail("invalid shared crop") }

try? FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(
  at: gifURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func renderFrame(_ index: Int) -> CGImage {
  let range = cellRange(index)
  let availableWidth = min(cropWidth, range.count - cropX)
  let sourceRect = CGRect(
    x: range.lowerBound + cropX,
    y: cropY,
    width: availableWidth,
    height: cropHeight
  )
  guard let cropped = normalized.cropping(to: sourceRect) else {
    fail("cannot crop frame \(index)")
  }

  guard let context = CGContext(
    data: nil,
    width: outputSize,
    height: outputSize,
    bitsPerComponent: 8,
    bytesPerRow: outputSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    fail("cannot create output bitmap context")
  }
  context.clear(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
  context.translateBy(x: 0, y: CGFloat(outputSize))
  context.scaleBy(x: 1, y: -1)
  context.interpolationQuality = .none

  let usable = CGFloat(outputSize - outputInset * 2)
  let scale = min(usable / CGFloat(cropWidth), usable / CGFloat(cropHeight))
  let drawWidth = floor(CGFloat(cropWidth) * scale)
  let drawHeight = floor(CGFloat(cropHeight) * scale)
  let drawRect = CGRect(
    x: floor((CGFloat(outputSize) - drawWidth) / 2),
    y: floor((CGFloat(outputSize) - drawHeight) / 2),
    width: drawWidth,
    height: drawHeight
  )
  context.draw(cropped, in: drawRect)
  guard let result = context.makeImage() else { fail("cannot render frame \(index)") }
  return result
}

func writePNG(_ image: CGImage, to url: URL) {
  guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
  ) else {
    fail("cannot create PNG destination")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

let frames = (0..<frameCount).map(renderFrame)
for (index, frame) in frames.enumerated() {
  writePNG(frame, to: framesURL.appendingPathComponent(String(format: "%@-%02d.png", name, index)))
}

guard let gif = CGImageDestinationCreateWithURL(
  gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil
) else {
  fail("cannot create GIF destination")
}

CGImageDestinationSetProperties(gif, [
  kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

let frameProperties = [
  kCGImagePropertyGIFDictionary: [
    kCGImagePropertyGIFDelayTime: frameDelay,
    kCGImagePropertyGIFUnclampedDelayTime: frameDelay
  ]
] as CFDictionary

for frame in frames {
  CGImageDestinationAddImage(gif, frame, frameProperties)
}
guard CGImageDestinationFinalize(gif) else { fail("cannot write \(gifURL.path)") }

print("wrote \(gifURL.path) and \(frameCount) PNG frames")
