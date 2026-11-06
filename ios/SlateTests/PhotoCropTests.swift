import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Slate

// MARK: - Where the crop square sits

final class CropGeometryTests: XCTestCase {
    private func geometry(_ width: CGFloat, _ height: CGFloat, side: CGFloat = 300) -> CropGeometry {
        CropGeometry(imageSize: CGSize(width: width, height: height), cropSide: side)
    }

    func testAtZoomOneALandscapePhotoShowsItsMiddleSquare() {
        let g = geometry(4000, 3000)
        XCTAssertEqual(g.coverScale, 0.1, accuracy: 1e-9)
        let rect = g.sourceRect(atZoom: 1, offset: .zero)
        XCTAssertEqual(rect.origin.x, 500, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(rect.width, 3000, accuracy: 0.01)
        XCTAssertEqual(rect.height, 3000, accuracy: 0.01)
    }

    func testAtZoomOneAPortraitPhotoShowsItsMiddleSquare() {
        let rect = geometry(3000, 4000).sourceRect(atZoom: 1, offset: .zero)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 500, accuracy: 0.01)
        XCTAssertEqual(rect.width, 3000, accuracy: 0.01)
    }

    func testASquarePhotoIsAllOfItAtZoomOne() {
        let rect = geometry(2000, 2000).sourceRect(atZoom: 1, offset: .zero)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(rect.width, 2000, accuracy: 0.01)
        XCTAssertEqual(rect.height, 2000, accuracy: 0.01)
    }

    func testDraggingALandscapePhotoRightShowsItsLeftSide() {
        let g = geometry(4000, 3000)   // 400 x 300 points at zoom 1, so it can slide 50 points either way
        XCTAssertEqual(g.sourceRect(atZoom: 1, offset: CGSize(width: 50, height: 0)).origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(g.sourceRect(atZoom: 1, offset: CGSize(width: -50, height: 0)).origin.x, 1000, accuracy: 0.01)
        XCTAssertEqual(g.sourceRect(atZoom: 1, offset: CGSize(width: 25, height: 0)).origin.x, 250, accuracy: 0.01)
    }

    func testTheOffsetStopsWhereTheEdgeOfThePhotoMeetsTheCircle() {
        let g = geometry(4000, 3000)
        XCTAssertEqual(g.clampedOffset(CGSize(width: 500, height: 0), atZoom: 1).width, 50, accuracy: 0.001)
        XCTAssertEqual(g.clampedOffset(CGSize(width: -500, height: 0), atZoom: 1).width, -50, accuracy: 0.001)
        // The short side already fits exactly, so it can't slide at all at zoom 1.
        XCTAssertEqual(g.clampedOffset(CGSize(width: 0, height: 80), atZoom: 1).height, 0, accuracy: 0.001)
    }

    func testZoomingInCutsOutAnSmallerPartAndLetsThePhotoSlideFurther() {
        let g = geometry(4000, 3000)
        XCTAssertEqual(g.sourceRect(atZoom: 2, offset: .zero).width, 1500, accuracy: 0.01)
        XCTAssertEqual(g.sourceRect(atZoom: 5, offset: .zero).width, 600, accuracy: 0.01)
        // At zoom 2 the photo is 800 x 600 points: 250 sideways and 150 up or down.
        let limit = g.clampedOffset(CGSize(width: 9999, height: 9999), atZoom: 2)
        XCTAssertEqual(limit.width, 250, accuracy: 0.001)
        XCTAssertEqual(limit.height, 150, accuracy: 0.001)
    }

    func testZoomStaysBetweenOneAndTheMaximum() {
        let g = geometry(4000, 3000)
        XCTAssertEqual(g.clampedZoom(0.2), 1)
        XCTAssertEqual(g.clampedZoom(99), CropGeometry.maxZoom)
        XCTAssertEqual(g.clampedZoom(.nan), 1)
        XCTAssertEqual(g.clampedZoom(2.5), 2.5)
    }

    func testTheCropNeverLeavesThePhoto() {
        for (w, h) in [(4000.0, 3000.0), (3000.0, 4000.0), (1000.0, 1000.0), (6000.0, 1500.0), (123.0, 4567.0)] {
            let g = geometry(w, h)
            for zoom in stride(from: 0.5, through: 7.0, by: 0.37) {
                for dx in stride(from: -1500.0, through: 1500.0, by: 123.0) {
                    for dy in stride(from: -1500.0, through: 1500.0, by: 211.0) {
                        let rect = g.sourceRect(atZoom: zoom, offset: CGSize(width: dx, height: dy))
                        XCTAssertGreaterThanOrEqual(rect.minX, -0.001, "\(w)x\(h) zoom \(zoom)")
                        XCTAssertGreaterThanOrEqual(rect.minY, -0.001)
                        XCTAssertLessThanOrEqual(rect.maxX, w + 0.001)
                        XCTAssertLessThanOrEqual(rect.maxY, h + 0.001)
                        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001, "It is always a square")
                    }
                }
            }
        }
    }

    func testAPhotoSmallerThanTheCircleIsStillUsable() {
        let g = geometry(100, 80, side: 300)
        XCTAssertEqual(g.coverScale, 3.75, accuracy: 1e-9)
        let rect = g.sourceRect(atZoom: 1, offset: .zero)
        XCTAssertEqual(rect.width, 80, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.01)
    }

    func testAPhotoWithNoSizeGivesNothingToCut() {
        let g = CropGeometry(imageSize: .zero, cropSide: 300)
        XCTAssertFalse(g.isUsable)
        XCTAssertEqual(g.sourceRect(atZoom: 1, offset: .zero), .zero)
        XCTAssertEqual(g.coverScale, 1)
    }

    func testNonsenseOffsetsAreTreatedAsZero() {
        let g = geometry(4000, 3000)
        XCTAssertEqual(g.clampedOffset(CGSize(width: .nan, height: .infinity), atZoom: 1), .zero)
    }
}

// MARK: - Reading and cutting a real picture

final class PhotoCropRenderTests: XCTestCase {
    /// 400 x 300 pixels: the left half red, the right half blue.
    private func twoColourPhoto() -> WorkingPhoto {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        }
        return WorkingPhoto(image: image)
    }

    /// The red, green and blue (0 to 255) of one pixel of a decoded picture.
    private func colour(of data: Data, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)? {
        guard let image = UIImage(data: data)?.cgImage,
              let piece = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(piece, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (Int(pixel[0]), Int(pixel[1]), Int(pixel[2])) : nil
    }

    func testTheCutComesFromWhereTheRectangleSays() throws {
        // x 100 to 400: 100 pixels of red, then 200 of blue.
        let data = try XCTUnwrap(PhotoCrop.croppedJPEG(from: twoColourPhoto(), rect: CGRect(x: 100, y: 0, width: 300, height: 300)))
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width * decoded.scale, 300, accuracy: 1)
        XCTAssertEqual(decoded.size.height * decoded.scale, 300, accuracy: 1)

        let left = try XCTUnwrap(colour(of: data, x: 20, y: 150))
        XCTAssertGreaterThan(left.red, 200)
        XCTAssertLessThan(left.blue, 70)
        let right = try XCTUnwrap(colour(of: data, x: 250, y: 150))
        XCTAssertGreaterThan(right.blue, 200)
        XCTAssertLessThan(right.red, 70)
    }

    func testABigCutIsReducedButASmallOneIsNotEnlarged() throws {
        let photo = twoColourPhoto()
        let reduced = try XCTUnwrap(PhotoCrop.croppedJPEG(from: photo, rect: CGRect(x: 0, y: 0, width: 300, height: 300), maxSide: 100))
        let reducedImage = try XCTUnwrap(UIImage(data: reduced))
        XCTAssertEqual(reducedImage.size.width, 100, accuracy: 1)

        let kept = try XCTUnwrap(PhotoCrop.croppedJPEG(from: photo, rect: CGRect(x: 0, y: 0, width: 300, height: 300)))
        let keptImage = try XCTUnwrap(UIImage(data: kept))
        XCTAssertEqual(keptImage.size.width, 300, accuracy: 1, "300 pixels stay 300, not 1024")
    }

    func testARectangleOutsideThePhotoGivesNothing() {
        XCTAssertNil(PhotoCrop.croppedJPEG(from: twoColourPhoto(), rect: CGRect(x: 900, y: 900, width: 100, height: 100)))
    }

    func testTheCropGeometryAndTheCutAgree() throws {
        // Slide a 400 x 300 photo fully left in a 300-point circle: the circle then shows the photo's right-hand square.
        let photo = twoColourPhoto()
        let g = CropGeometry(imageSize: photo.image.size, cropSide: 300)
        let rect = g.sourceRect(atZoom: 1, offset: CGSize(width: -9999, height: 0))
        XCTAssertEqual(rect, CGRect(x: 100, y: 0, width: 300, height: 300))
        let data = try XCTUnwrap(PhotoCrop.croppedJPEG(from: photo, rect: rect))
        let blue = try XCTUnwrap(colour(of: data, x: 280, y: 20))
        XCTAssertGreaterThan(blue.blue, 200)
    }

    func testAWorkingPhotoIsShrunkToTheLongEdge() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        }
        let data = try XCTUnwrap(wide.jpegData(compressionQuality: 0.8))
        let working = try XCTUnwrap(PhotoCrop.workingPhoto(from: data))
        XCTAssertEqual(working.image.size.width, 2048, accuracy: 1)
        XCTAssertEqual(working.image.size.height, 683, accuracy: 2)
    }

    func testAWorkingPhotoComesOutUpright() throws {
        // A 300 x 100 picture whose camera rotation says "turn it a quarter": it should be 100 wide and 300 tall.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let flat = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 100), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        }
        let cgImage = try XCTUnwrap(flat.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let working = try XCTUnwrap(PhotoCrop.workingPhoto(from: output as Data))
        XCTAssertEqual(working.image.size.width, 100, accuracy: 1)
        XCTAssertEqual(working.image.size.height, 300, accuracy: 1)
    }

    func testSomethingThatIsNotAPictureGivesNothing() {
        XCTAssertNil(PhotoCrop.workingPhoto(from: Data([1, 2, 3, 4])))
        XCTAssertNil(PhotoCrop.workingPhoto(from: Data()))
    }
}
