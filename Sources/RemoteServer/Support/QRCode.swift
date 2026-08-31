import Foundation
import CoreImage
import CoreGraphics

/// Renders a QR code as terminal text.
///
/// Uses CoreImage's built-in generator rather than a QR library — no dependency, and the
/// same generator the menu-bar app will use for its on-screen code in Phase 4.
///
/// Each output character is two vertical pixels (upper half block), so the code stays
/// square-ish in a terminal cell grid and small enough to scan from a phone.
public enum QRCode {

    public static func terminalString(for text: String, quietZone: Int = 2) -> String? {
        guard let matrix = matrix(for: text) else { return nil }

        let size = matrix.count
        let padded = size + quietZone * 2
        func isDark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quietZone, my = y - quietZone
            guard mx >= 0, my >= 0, mx < size, my < size else { return false }
            return matrix[my][mx]
        }

        // A phone camera needs light modules to be *light*. Terminals vary, so we print
        // explicit background/foreground rather than relying on the user's theme.
        let white = "\u{1B}[47m"
        let black = "\u{1B}[40m"
        let reset = "\u{1B}[0m"

        var lines: [String] = []
        for y in stride(from: 0, to: padded, by: 2) {
            var line = ""
            var currentDark: Bool?
            for x in 0..<padded {
                let top = isDark(x, y)
                let bottom = isDark(x, y + 1)
                // Foreground colour draws the top half, background the bottom half.
                let glyph: String
                switch (top, bottom) {
                case (false, false): glyph = " "
                case (true, true):   glyph = "\u{2588}"
                case (true, false):  glyph = "\u{2580}"
                case (false, true):  glyph = "\u{2584}"
                }
                if currentDark != true {
                    line += white
                    currentDark = true
                }
                line += (top || bottom) ? "\u{1B}[30m" + glyph + "\u{1B}[39m" : glyph
            }
            lines.append(line + reset)
        }
        return lines.joined(separator: "\n")
    }

    /// Renders the code as an image, one pixel per module plus a quiet zone.
    ///
    /// Deliberately unscaled: the caller magnifies it with nearest-neighbour filtering, so
    /// the modules stay perfectly square at any size. Smoothing a QR code is the fastest way
    /// to make it unscannable, and it is exactly what a naive image resize does.
    ///
    /// The quiet zone is not optional decoration — a code drawn flush against other content
    /// often will not scan at all.
    public static func cgImage(for text: String, quietZone: Int = 3) -> CGImage? {
        guard let matrix = matrix(for: text), !matrix.isEmpty else { return nil }
        let size = matrix.count
        let side = size + quietZone * 2

        var pixels = [UInt8](repeating: 255, count: side * side)
        for (row, cells) in matrix.enumerated() {
            for (column, isDark) in cells.enumerated() where isDark {
                pixels[(row + quietZone) * side + (column + quietZone)] = 0
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        return context.makeImage()
    }

    /// The module matrix, `true` where a module is dark.
    public static func matrix(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // M: 15% error correction. Enough for a screen, without inflating the module count
        // to the point where a phone struggles at couch distance.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: true])
        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cgImage = context.createCGImage(output, from: extent) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let bitmap = CGContext(data: &pixels, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (0..<height).map { y in
            (0..<width).map { x in pixels[y * width + x] < 128 }
        }
    }
}
