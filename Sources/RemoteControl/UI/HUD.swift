import AppKit
import SwiftUI

/// Transient on-screen overlays: the mode/enable banner and the scroll-mode indicator by the cursor.
@MainActor
final class HUD {
    static let shared = HUD()

    private var banner: NSPanel?
    private var bannerHide: DispatchWorkItem?
    private var indicator: NSPanel?

    func show(symbol: String, title: String, duration: TimeInterval = 1.1) {
        let size = NSSize(width: 200, height: 160)
        let panel = banner ?? Self.makePanel(size: size)
        banner = panel
        panel.contentView = NSHostingView(rootView: BannerView(symbol: symbol, title: title).frame(width: size.width, height: size.height))

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.18))
        }
        bannerHide?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let hide = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel?.orderOut(nil) }
            })
        }
        bannerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hide)
    }

    /// `point` is in CoreGraphics global coordinates (origin top-left of the main display).
    func showScrollIndicator(at point: CGPoint) {
        let size = NSSize(width: 44, height: 44)
        let panel = indicator ?? Self.makePanel(size: size)
        indicator = panel
        if panel.contentView == nil || !(panel.contentView is NSHostingView<ScrollIndicatorView>) {
            panel.contentView = NSHostingView(rootView: ScrollIndicatorView())
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrameOrigin(NSPoint(x: point.x + 18, y: mainHeight - point.y - 18 - size.height))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hideScrollIndicator() {
        indicator?.orderOut(nil)
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct BannerView: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .regular))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct ScrollIndicatorView: View {
    var body: some View {
        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.accentColor.opacity(0.9), in: Circle())
    }
}
