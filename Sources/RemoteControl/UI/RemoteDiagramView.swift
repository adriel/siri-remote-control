import RemoteCore
import SwiftUI

/// A drawing of the Siri Remote that lights up pressed buttons and shows where the finger is on the clickpad.
struct RemoteDiagramView: View {
    let pressed: Set<RemoteButton>
    /// Normalised clickpad position, y up.
    let touch: CGPoint?
    /// A button to point out (e.g. the mapping row under the pointer), drawn softer than a real press.
    var highlighted: RemoteButton?

    private func isLit(_ button: RemoteButton) -> Bool { pressed.contains(button) || highlighted == button }

    private func fill(_ button: RemoteButton, otherwise base: Color) -> Color {
        if pressed.contains(button) { return .accentColor }
        if highlighted == button { return Color.accentColor.opacity(0.6) }
        return base
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = w * 0.82
            let padCenter = CGPoint(x: w / 2, y: h * 0.07 + w * 0.12 + pad / 2)
            let small = w * 0.33
            let colLeft = w * 0.29
            let colRight = w * 0.71
            let row1 = padCenter.y + pad / 2 + small * 0.75
            let row2 = row1 + small * 1.2
            let row3 = row2 + small * 1.2

            ZStack {
                RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.68)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.22, style: .continuous).stroke(Color.black.opacity(0.25), lineWidth: 0.5))

                // Siri button on the right edge.
                Capsule()
                    .fill(fill(.siri, otherwise: Color(white: 0.75)))
                    .frame(width: w * (isLit(.siri) ? 0.05 : 0.035), height: h * 0.1)
                    .position(x: w - w * 0.01, y: padCenter.y - pad * 0.12)

                // Microphone slot and power.
                Capsule().fill(Color.black.opacity(0.8)).frame(width: w * 0.08, height: w * 0.035)
                    .position(x: w / 2, y: h * 0.07)
                circleButton(.power, diameter: w * 0.17, symbol: "power", fill: .clear, ring: true)
                    .position(x: w * 0.79, y: h * 0.07)

                clickpad(diameter: pad)
                    .position(padCenter)

                circleButton(.back, diameter: small, symbol: "chevron.left").position(x: colLeft, y: row1)
                circleButton(.tv, diameter: small, symbol: "tv").position(x: colRight, y: row1)
                circleButton(.playPause, diameter: small, symbol: "playpause").position(x: colLeft, y: row2)
                circleButton(.mute, diameter: small, symbol: "speaker.slash").position(x: colLeft, y: row3)
                volumeRocker(width: small, height: small * 2.2).position(x: colRight, y: (row2 + row3) / 2)
            }
        }
        .aspectRatio(1 / 3, contentMode: .fit)
    }

    private func clickpad(diameter d: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.1))
            ForEach([RemoteButton.up, .right, .down, .left], id: \.self) { button in
                if isLit(button) {
                    RingSegment(index: [.up: 0, .right: 1, .down: 2, .left: 3][button]!)
                        .fill(Color.accentColor.opacity(pressed.contains(button) ? 0.85 : 0.5))
                }
            }
            Circle()
                .fill(fill(.select, otherwise: Color(white: 0.06)))
                .overlay(Circle().stroke(Color.white.opacity(0.08)))
                .frame(width: d * 0.56, height: d * 0.56)
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(Color.white.opacity(0.5)).frame(width: 2.5, height: 2.5)
                    .offset(y: -d * 0.43)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            if let touch {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: d * 0.12, height: d * 0.12)
                    .shadow(color: .accentColor, radius: 4)
                    .position(x: touch.x * d, y: (1 - touch.y) * d)
            }
        }
        .frame(width: d, height: d)
    }

    private func circleButton(_ button: RemoteButton, diameter: CGFloat, symbol: String, fill: Color = Color(white: 0.08), ring: Bool = false) -> some View {
        let on = isLit(button)
        return ZStack {
            Circle().fill(self.fill(button, otherwise: fill))
            if ring { Circle().stroke(Color.black.opacity(0.6), lineWidth: 1) }
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .medium))
                .foregroundStyle(ring && !on ? Color.black.opacity(0.75) : .white)
        }
        .frame(width: diameter, height: diameter)
    }

    private func volumeRocker(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Capsule().fill(Color(white: 0.08))
            VStack(spacing: 0) {
                Rectangle().fill(fill(.volumeUp, otherwise: .clear))
                Rectangle().fill(fill(.volumeDown, otherwise: .clear))
            }
            .clipShape(Capsule())
            VStack {
                Image(systemName: "plus")
                Spacer()
                Image(systemName: "minus")
            }
            .font(.system(size: width * 0.36, weight: .medium))
            .foregroundStyle(.white)
            .padding(.vertical, height * 0.12)
        }
        .frame(width: width, height: height)
    }
}

/// One quarter of the clickpad ring (0 = top, then clockwise).
private struct RingSegment: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width / 2
        let inner = outer * 0.56
        let mid = -90.0 + Double(index) * 90
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .degrees(mid - 45), endAngle: .degrees(mid + 45), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .degrees(mid + 45), endAngle: .degrees(mid - 45), clockwise: true)
        path.closeSubpath()
        return path
    }
}
