import SwiftUI
import MacIDCore

/// The sensitivity slider, drawn on a distance axis next to the closest stranger.
struct SensitivityControl: View {
    @EnvironmentObject private var model: AppModel

    private let axisFrom: Float = 0.40
    private let axisTo: Float = 0.80

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let x = { (d: Float) in CGFloat((d - axisFrom) / (axisTo - axisFrom)) * width }
                let lo = x(Config.strictest)
                let hi = x(Config.loosest)
                let thumb = x(Config.threshold(for: model.config.sensitivity))
                let stranger = x(Config.closestStranger)

                ZStack(alignment: .topLeading) {
                    Text("Secure").font(.caption).foregroundStyle(.secondary)
                        .position(x: lo + 20, y: 6)
                    Text("Convenient").font(.caption).foregroundStyle(.secondary)
                        .position(x: hi - 32, y: 6)
                    Text("closest stranger").font(.caption).foregroundStyle(.orange)
                        .fixedSize()
                        .position(x: min(stranger, width - 46), y: 6)

                    Rectangle().fill(Color.secondary.opacity(0.3))
                        .frame(width: width, height: 2)
                        .position(x: width / 2, y: 30)
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: hi - lo, height: 6)
                        .position(x: (lo + hi) / 2, y: 30)
                    Circle().fill(.orange)
                        .frame(width: 8, height: 8)
                        .position(x: stranger, y: 30)
                    Circle().fill(.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .shadow(radius: 1)
                        .frame(width: 18, height: 18)
                        .position(x: thumb, y: 30)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = (drag.location.x - lo) / max(1, hi - lo)
                    let step = Config.sensitivityStep
                    let value = (Double(min(1, max(0, fraction))) / step).rounded() * step
                    if value != model.config.sensitivity { model.setSensitivity(value) }
                })
            }
            .frame(height: 40)

            Text(String(format: "Recognizes you %.1f%% of the time. No stranger in 767 test pairs gets in.",
                        Config.measuredAcceptance(for: model.config.sensitivity)))
                .font(.callout)
                .monospacedDigit()
        }
    }
}
