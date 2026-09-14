import Testing

@testable import LatheCore

@Suite("Resize arithmetic")
struct ResizeTargetTests {

    private let landscape = PixelSize(width: 4032, height: 3024)
    private let square = PixelSize(width: 1000, height: 1000)

    @Test("none leaves the size alone")
    func noneIsIdentity() {
        #expect(ResizeTarget.none.resolve(from: landscape) == landscape)
    }

    @Test("fit preserves aspect ratio")
    func fitPreservesAspect() {
        let result = ResizeTarget.fit(PixelSize(width: 2016, height: 2016)).resolve(from: landscape)
        #expect(result == PixelSize(width: 2016, height: 1512))
    }

    @Test("longestSide caps the long edge")
    func longestSideCaps() {
        let result = ResizeTarget.longestSide(1024).resolve(from: landscape)
        #expect(result.longestSide == 1024)
        #expect(result == PixelSize(width: 1024, height: 768))
    }

    /// The trap this type exists to close: a target larger than the source must
    /// never enlarge it.
    @Test("nothing ever upsamples", arguments: [
        ResizeTarget.fit(PixelSize(width: 9000, height: 9000)),
        ResizeTarget.longestSide(9000),
        ResizeTarget.scale(4),
        ResizeTarget.maxPixels(Int.max),
    ])
    func neverUpsamples(target: ResizeTarget) {
        let result = target.resolve(from: square)
        #expect(result.width <= square.width)
        #expect(result.height <= square.height)
        #expect(result == square)
    }

    @Test("scale halves both dimensions")
    func scaleHalves() {
        #expect(ResizeTarget.scale(0.5).resolve(from: square) == PixelSize(width: 500, height: 500))
    }

    /// `maxPixels` is a hard ceiling, not a target: rounding must never take the
    /// result back over the cap.
    @Test("maxPixels caps total area while keeping aspect")
    func maxPixelsCapsArea() {
        let result = ResizeTarget.maxPixels(1_000_000).resolve(from: landscape)
        #expect(result.pixelCount <= 1_000_000)
        let sourceAspect = Double(landscape.width) / Double(landscape.height)
        let resultAspect = Double(result.width) / Double(result.height)
        #expect(abs(sourceAspect - resultAspect) < 0.01)
    }

    /// The cap is honoured exactly, except where honouring it would require a
    /// dimension below one pixel — the one documented escape, and the reason an
    /// 8000x17 banner is in the fixture list.
    @Test("maxPixels is never exceeded, at any cap", arguments: [
        1, 2, 999, 1_000, 65_536, 1_000_000, 4_000_000, 12_000_000,
    ])
    func maxPixelsNeverExceeded(cap: Int) {
        for source in [landscape, square, PixelSize(width: 8000, height: 17)] {
            let result = ResizeTarget.maxPixels(cap).resolve(from: source)
            let hitTheOnePixelFloor = min(result.width, result.height) == 1
            #expect(result.pixelCount <= cap || result == source || hitTheOnePixelFloor,
                    "cap \(cap) from \(source) gave \(result)")
            #expect(result.width >= 1 && result.height >= 1)
        }
    }

    @Test("degenerate inputs are returned unchanged rather than crashing", arguments: [
        PixelSize(width: 0, height: 0),
        PixelSize(width: 0, height: 100),
        PixelSize(width: -5, height: 10),
    ])
    func degenerateInputs(size: PixelSize) {
        #expect(ResizeTarget.longestSide(100).resolve(from: size) == size)
        #expect(ResizeTarget.fit(PixelSize(width: 10, height: 10)).resolve(from: size) == size)
    }

    @Test("output is never zero in either dimension")
    func neverCollapsesToZero() {
        let wide = PixelSize(width: 10_000, height: 3)
        let result = ResizeTarget.longestSide(100).resolve(from: wide)
        #expect(result.width >= 1)
        #expect(result.height >= 1)
    }
}
