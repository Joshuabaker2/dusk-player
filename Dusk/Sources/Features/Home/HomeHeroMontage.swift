import SwiftUI

/// A dominant image plus up to four distinct, angled landscape panels.
/// Geometry is normalized to the hero, not the screen or an individual tile.
struct HomeHeroMontage: View {
    let images: [Image]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let primary = images.first {
                ZStack(alignment: .topLeading) {
                    primary
                        .resizable()
                        .aspectRatio(contentMode: images.count > 1 ? .fill : .fit)
                        .frame(width: size.width * (images.count > 1 ? 0.77 : 0.70), height: size.height, alignment: .top)
                        .clipped()
                        .offset(x: size.width * (images.count > 1 ? 0 : 0.30))

                    ForEach(Array(panels.prefix(max(0, images.count - 1)).enumerated()), id: \.offset) { index, points in
                        montagePanel(images[index + 1], points: points, size: size)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var panels: [[CGPoint]] {
        switch images.count {
        case ...1:
            []
        case 2:
            [points([(0.60, 0), (1, 0), (1, 1), (0.51, 1)])]
        case 3:
            [
                points([(0.60, 0), (1, 0), (1, 0.50), (0.55, 0.55)]),
                points([(0.55, 0.55), (1, 0.50), (1, 1), (0.50, 1)]),
            ]
        case 4:
            [
                points([(0.56, 0), (0.77, 0), (0.735, 0.44), (0.52, 0.52)]),
                points([(0.77, 0), (1, 0), (1, 0.50), (0.735, 0.44)]),
                points([(0.52, 0.52), (0.735, 0.44), (1, 0.50), (1, 1), (0.48, 1)]),
            ]
        default:
            [
                points([(0.56, 0), (0.77, 0), (0.735, 0.44), (0.52, 0.52)]),
                points([(0.77, 0), (1, 0), (1, 0.50), (0.735, 0.44)]),
                points([(0.52, 0.52), (0.735, 0.44), (0.70, 1), (0.48, 1)]),
                points([(0.735, 0.44), (1, 0.50), (1, 1), (0.70, 1)]),
            ]
        }
    }

    private func points(_ values: [(CGFloat, CGFloat)]) -> [CGPoint] {
        values.map { CGPoint(x: $0.0, y: $0.1) }
    }

    private func montagePanel(_ image: Image, points: [CGPoint], size: CGSize) -> some View {
        let left = (points.map(\.x).min() ?? 0) * size.width
        let top = (points.map(\.y).min() ?? 0) * size.height
        let width = (points.map(\.x).max() ?? 1) * size.width - left
        let height = (points.map(\.y).max() ?? 1) * size.height - top
        let localPoints = points.map {
            CGPoint(x: ($0.x * size.width - left) / max(width, 1), y: ($0.y * size.height - top) / max(height, 1))
        }
        let shape = HomeHeroMontagePanel(points: localPoints)
        return image
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay(shape.stroke(Color.black.opacity(0.65), lineWidth: 2))
            .offset(x: left, y: top)
    }
}

private struct HomeHeroMontagePanel: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let position = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            path.closeSubpath()
        }
    }
}
