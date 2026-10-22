import SwiftUI

/// Keep the tip at the view's bottom center, matching Annotation's .bottom anchor.
struct DeliveryMapPin: View {
    let sequence: String
    let unit: String
    let building: String
    let color: Color
    let selected: Bool
    var estimated = false
    var referenceLabel: String? = nil
    var referenceDisclaimer = "Not a door"

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if estimated { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                Text(referenceLabel ?? (building.isEmpty ? unit : "\(unit) · B\(building)"))
            }
                .font(.caption.bold()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(selected ? 1 : 0.6), lineWidth: selected ? 2 : 1))
            if referenceLabel != nil { Text(referenceDisclaimer).font(.caption2.bold()).padding(3).background(.regularMaterial, in: Capsule()) }
            DeliveryPinShape()
                .fill(color)
                .overlay(DeliveryPinShape().stroke(.black.opacity(0.9), lineWidth: 5))
                .overlay(DeliveryPinShape().stroke(.white, lineWidth: 2))
                .overlay(alignment: .top) {
                    Text(sequence).font(.caption2.bold()).monospacedDigit()
                        .foregroundStyle(.black).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 18, height: 18).background(.white, in: Circle())
                        .padding(.top, 7)
                }
                .frame(width: 32, height: 44).clipped()
        }
        .fixedSize().frame(minWidth: 44).contentShape(Rectangle())
    }
}

private struct DeliveryPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.5, 1))
        path.addCurve(to: point(0.09, 0.36), control1: point(0.32, 0.8), control2: point(0.09, 0.6))
        path.addCurve(to: point(0.5, 0.07), control1: point(0.09, 0.2), control2: point(0.27, 0.07))
        path.addCurve(to: point(0.91, 0.36), control1: point(0.73, 0.07), control2: point(0.91, 0.2))
        path.addCurve(to: point(0.5, 1), control1: point(0.91, 0.6), control2: point(0.68, 0.8))
        path.closeSubpath()
        return path
    }
}
