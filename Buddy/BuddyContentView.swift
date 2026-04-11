import AppKit

class BuddyContentView: NSView {
    weak var character: BuddyCharacter?
    private var isDragging = false
    private var dragOffset = NSPoint.zero
    private var longPressTimer: Timer?
    private var didLongPress = false

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let renderer = character?.spriteRenderer else { return nil }
        return renderer.isOpaqueAt(point: point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        didLongPress = false
        guard let win = window else { return }
        let screenLoc = NSEvent.mouseLocation
        dragOffset = NSPoint(
            x: screenLoc.x - win.frame.origin.x,
            y: screenLoc.y - win.frame.origin.y
        )

        // Start long press timer (1 second hold = voice mode)
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self = self, !self.isDragging else { return }
            self.didLongPress = true
            self.character?.toggleVoice()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        longPressTimer?.invalidate()
        longPressTimer = nil
        if !isDragging {
            isDragging = true
            character?.stopForDrag()
        }
        let screenLoc = NSEvent.mouseLocation
        let newOrigin = NSPoint(
            x: screenLoc.x - dragOffset.x,
            y: screenLoc.y - dragOffset.y
        )
        win.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        if isDragging {
            isDragging = false
            character?.startFalling()
        } else if !didLongPress {
            character?.handleClick()
        }
        didLongPress = false
    }
}
