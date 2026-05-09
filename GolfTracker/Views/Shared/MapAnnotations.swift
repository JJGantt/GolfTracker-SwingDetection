import SwiftUI
import CoreLocation

struct GolfBallMarker: View {
    let strokeNumber: Int
    var size: CGFloat = 25

    var body: some View {
        ZStack {
            // Main golf ball circle
            Circle()
                .fill(.white)
                .frame(width: size, height: size)

            // Shadow/3D effect
            Circle()
                .stroke(.gray.opacity(0.3), lineWidth: 1)
                .frame(width: size, height: size)

            // Dimples pattern
            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(.gray.opacity(0.15))
                        .frame(width: size * 0.15, height: size * 0.15)
                        .offset(x: cos(Double(i) * .pi / 3) * (size * 0.25),
                                y: sin(Double(i) * .pi / 3) * (size * 0.25))
                }
            }

            // Stroke number
            Text("\(strokeNumber)")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.black)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}

struct UserLocationMarker: View {
    let heading: CLLocationDirection?
    /// User's playgroup color (or default blue when solo). Watch renders
    /// its own user dot in the same color via `store.myPlayerColor` —
    /// keeping the iOS marker color-aware brings them in sync.
    var color: Color = .blue

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 30))
            .foregroundColor(color)
            .rotationEffect(.degrees(heading ?? 0))
            .shadow(color: .white, radius: 2)
            .shadow(color: .black.opacity(0.3), radius: 1)
    }
}

struct HoleMarker: View {
    let number: Int
    var isNearest: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isNearest ? .orange : .red)
                .frame(width: isNearest ? 35 : 30, height: isNearest ? 35 : 30)
            if isNearest {
                Circle()
                    .stroke(.yellow, lineWidth: 3)
                    .frame(width: 35, height: 35)
            }
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
    }
}
