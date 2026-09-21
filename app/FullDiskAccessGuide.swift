import AppKit
import SwiftUI

/// Opens Full Disk Access in System Settings and floats a small panel beside it
/// holding MacID's icon, which the user drags into the list.
@MainActor
enum FullDiskAccessGuide {
    private static var panel: NSPanel?
    private static var follow: Timer?

    static var isShown: Bool { panel != nil }

    static func show() {
        FullDiskAccess.openSettingsPane()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: GuideCard.size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: GuideCard())
            self.panel = panel
        }
        place()

        // System Settings opens a moment later and may be moved; keep the panel beside it.
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in place() }
        }
    }

    static func hide() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Floats the panel over the bottom of the System Settings window, centred on its right-hand
    /// pane where the Full Disk Access list is. Hidden whenever that window isn't on screen,
    /// such as when the user switches to another Space or a full-screen app.
    private static func place() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        guard let settings = settingsWindowFrame() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let size = GuideCard.size
        // CoreGraphics measures from the top of the primary screen; AppKit from the bottom.
        let bottom = screen.frame.maxY - settings.maxY
        // The sidebar takes roughly the left third; the list sits in the rest.
        let origin = CGPoint(x: settings.minX + settings.width * 0.65 - size.width / 2, y: bottom + 24)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func settingsWindowFrame() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerName as String] as? String) == "System Settings",
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 200 else { continue }
            return frame
        }
        return nil
    }
}

private struct GuideCard: View {
    static let size = CGSize(width: 340, height: 96)

    var body: some View {
        HStack(spacing: 16) {
            AppIconDragSource()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Label("Drag MacID into the list", systemImage: "arrow.up")
                    .font(.headline)
                Text("Then make sure its switch is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The app icon as a drag source for MacID.app's file URL, usable without first activating the panel.
private struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
