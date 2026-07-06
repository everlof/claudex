import AppKit

extension NSImage {
    /// Return a copy of this (template) image filled with `color`. Used to tint the
    /// menu-bar gauge with the frontmost account's provider colour.
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
