import AppKit

/// A sticky alignment line, stored in global screen coordinates (AppKit's
/// bottom-left origin on the primary display, so a guide keeps its place when
/// the pointer wanders onto another monitor).
struct Guide: Identifiable, Codable, Equatable {
    enum Orientation: String, Codable {
        case horizontal
        case vertical
    }

    var id = UUID()
    var orientation: Orientation
    var position: Double
}

/// The guides the user has dropped. Persisted, because a guide you laid down
/// yesterday to check a header height should still be there today.
@MainActor
final class GuideStore: ObservableObject {
    @Published private(set) var guides: [Guide] = [] {
        didSet {
            persist()
            onChange?()
        }
    }

    /// Fired whenever the set changes, so the overlay can redraw.
    var onChange: (() -> Void)?

    private var loading = false
    private static var fileURL: URL {
        SettingsStore.supportDirectory.appendingPathComponent("guides.json")
    }

    init() {
        load()
    }

    var isEmpty: Bool { guides.isEmpty }

    /// Drops a crossed pair at the pointer — the crosshair, made permanent.
    func dropAtPointer() {
        let point = NSEvent.mouseLocation
        guides.append(contentsOf: [
            Guide(orientation: .vertical, position: Double(point.x.rounded())),
            Guide(orientation: .horizontal, position: Double(point.y.rounded())),
        ])
    }

    func drop(_ orientation: Guide.Orientation, at position: Double) {
        guides.append(Guide(orientation: orientation, position: position.rounded()))
    }

    func clear() {
        guard !guides.isEmpty else { return }
        guides.removeAll()
    }

    /// Removes whichever guide sits nearest the point, if one is close enough.
    func removeNearest(to point: NSPoint, within tolerance: CGFloat = 8) {
        let scored = guides.enumerated().map { index, guide -> (Int, CGFloat) in
            let distance = guide.orientation == .vertical
                ? abs(CGFloat(guide.position) - point.x)
                : abs(CGFloat(guide.position) - point.y)
            return (index, distance)
        }
        guard let nearest = scored.min(by: { $0.1 < $1.1 }), nearest.1 <= tolerance else { return }
        guides.remove(at: nearest.0)
    }

    /// Pulls a point onto nearby guides, one axis at a time.
    func snapped(_ point: NSPoint, within tolerance: CGFloat) -> NSPoint {
        guard tolerance > 0 else { return point }
        var result = point
        var bestX: CGFloat = tolerance
        var bestY: CGFloat = tolerance
        for guide in guides {
            switch guide.orientation {
            case .vertical:
                let distance = abs(CGFloat(guide.position) - point.x)
                if distance <= bestX {
                    bestX = distance
                    result.x = CGFloat(guide.position)
                }
            case .horizontal:
                let distance = abs(CGFloat(guide.position) - point.y)
                if distance <= bestY {
                    bestY = distance
                    result.y = CGFloat(guide.position)
                }
            }
        }
        return result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode([Guide].self, from: data)
        else { return }
        loading = true
        guides = stored
        loading = false
    }

    private func persist() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(guides) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
