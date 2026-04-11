import AppKit

class CharacterRenderer {
    let gridSize = 16
    let scale = 5
    let displaySize: CGFloat = 80

    private var frameImages: [CGImage] = []
    let layer = CALayer()

    enum Frame: Int {
        case idle = 0
        case walkA = 1
        case walkB = 2
        case blink = 3
        case happy = 4
        case surprised = 5
        case angry = 6
        case sad = 7
        case love = 8
        case sleepy = 9
        case smug = 10
        case scared = 11
        case dead = 12
        case wink = 13
        case celebrate = 14
        case drinking = 15
        case stretching = 16
        case concerned = 17
        case focused = 18
        case cheering = 19
    }

    private var currentIdleData: [[Int]] = []

    init() {
        layer.frame = CGRect(x: 0, y: 0, width: displaySize, height: displaySize)
        layer.contentsGravity = .center
        layer.magnificationFilter = .nearest
        loadPack(CharacterPack.spiderMan)
    }

    func setFrame(_ frame: Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = frameImages[frame.rawValue]
        CATransaction.commit()
    }

    private var currentlyFlipped = false

    func setFlipped(_ flipped: Bool) {
        guard flipped != currentlyFlipped else { return }
        currentlyFlipped = flipped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = flipped ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    func isOpaqueAt(point: NSPoint) -> Bool {
        let col = Int(point.x) / scale
        let row = gridSize - 1 - Int(point.y) / scale
        guard row >= 0, row < gridSize, col >= 0, col < gridSize else { return false }
        return currentIdleData[row][col] != 0
    }

    // MARK: - Load Character Pack

    func loadPack(_ pack: CharacterPack) {
        frameImages.removeAll()
        let frames = pack.allFrames
        for data in frames {
            frameImages.append(renderFrameWithPalette(data, palette: pack.colorPalette))
        }
        if let first = frames.first { currentIdleData = first }
        layer.contents = frameImages[0]
    }

    private func renderFrameWithPalette(_ data: [[Int]], palette: [(r: Double, g: Double, b: Double, a: Double)]) -> CGImage {
        let size = gridSize * scale
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let val = data[row][col]
                if val == 0 || val >= palette.count { continue }

                let color = palette[val]
                ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)

                let flippedRow = gridSize - 1 - row
                ctx.fill(CGRect(x: col * scale, y: flippedRow * scale, width: scale, height: scale))
            }
        }

        return ctx.makeImage()!
    }
}
