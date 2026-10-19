import XCTest
import SwiftUI
import UIKit
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class LocationDirectionRenderingTests: XCTestCase {
    /// Removing/reversing camera subtraction must change the actual blue pixels, not just metadata.
    func testRenderedArrowUsesTheActualMapBearing() throws {
        var state = NavigationDirectionState()
        let now = Date()
        state.receiveCourse(degrees: 270, accuracy: 5, speed: 1.2, speedAccuracy: 0.1,
                            positionAccuracy: 5, timestamp: now, at: now)
        let direction = try XCTUnwrap(state.direction)
        let west = try blueCentroid(direction: direction, mapHeading: 0)
        let up = try blueCentroid(direction: direction, mapHeading: 270)
        let referenceUp = try upReferenceCentroid()
        // The arrow's wider rear has more blue area than its tip: rear centroid is east for a west arrow.
        XCTAssertGreaterThan(west.x, 41.5)
        XCTAssertEqual(west.y, 40, accuracy: 1.5)
        XCTAssertEqual(up.x, 40, accuracy: 1.5)
        XCTAssertGreaterThan(abs(up.y - 40), 1.5)
        XCTAssertGreaterThan(abs(referenceUp.y - 40), 1.5)
        XCTAssertGreaterThan((up.y - 40) * (referenceUp.y - 40), 0,
                             "The blue arrow must face up, not down; normalize bitmap Y against an independent up triangle")
    }

    private func blueCentroid(direction: NavigationDirection, mapHeading: Double) throws -> CGPoint {
        let size = CGSize(width: 80, height: 80)
        let renderer = ImageRenderer(content:
            MapLocationDirection(direction: direction, mapHeading: mapHeading, accessibilityID: "test.arrow")
                .frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "The real SwiftUI arrow must render successfully")
        return try pixelCentroid(XCTUnwrap(image.cgImage))
    }

    private func upReferenceCentroid() throws -> CGPoint {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { _ in
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: 40, y: 24))
            triangle.addLine(to: CGPoint(x: 52, y: 56))
            triangle.addLine(to: CGPoint(x: 28, y: 56))
            triangle.close()
            UIColor.systemBlue.setFill(); triangle.fill()
        }
        return try pixelCentroid(XCTUnwrap(image.cgImage))
    }

    private func pixelCentroid(_ cgImage: CGImage) throws -> CGPoint {
        let size = CGSize(width: 80, height: 80)
        var pixels = [UInt8](repeating: 0, count: 80 * 80 * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 80, height: 80, bitsPerComponent: 8,
                bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            var count = 0, xTotal = 0, yTotal = 0
            for y in 0..<80 {
                for x in 0..<80 {
                    let offset = (y * 80 + x) * 4
                    let red = Int(buffer[offset]), green = Int(buffer[offset + 1]), blue = Int(buffer[offset + 2])
                    if buffer[offset + 3] > 200, blue > red + 80, blue > green + 40 {
                        count += 1; xTotal += x; yTotal += y
                    }
                }
            }
            XCTAssertGreaterThan(count, 100, "Missing or empty blue arrow cannot pass the rendering test")
            guard count > 0 else { throw CocoaError(.coderInvalidValue) }
            return CGPoint(x: Double(xTotal) / Double(count), y: Double(yTotal) / Double(count))
        }
    }
}
