import SwiftUI
import UIKit

enum CatalogKind: String, CaseIterable, Identifiable {
    case all = "All", shape = "Shapes", graph = "Graphs", latex = "Equations"
    case text = "Notes", widget = "Interactive", frame = "Pages", image = "Images"
    var id: String { rawValue }
    var objectKind: String? {
        switch self {
        case .all: return nil
        case .shape: return "shape"
        case .graph: return "graph"
        case .latex: return "latex"
        case .text: return "text"
        case .widget: return "widget"
        case .frame: return "frame"
        case .image: return "image"
        }
    }
    static func title(_ kind: String) -> String { allCases.first { $0.objectKind == kind }?.rawValue ?? kind.capitalized }
    static func icon(_ kind: String) -> String {
        switch kind {
        case "shape": return "square.on.circle"
        case "graph": return "chart.xyaxis.line"
        case "latex": return "function"
        case "text": return "text.alignleft"
        case "widget": return "hand.tap"
        case "frame": return "doc"
        case "image": return "photo"
        default: return "shippingbox"
        }
    }
}

@MainActor
enum CatalogThumbnailRenderer {
    static func image(for object: CanvasObject, size: CGSize = CGSize(width: 360, height: 210)) -> UIImage? {
        // Browsing never instantiates a web view or executes object code.
        if object.kind == "widget" { return ObjectRenderer.shared.widgetSnapshots[object.id] }
        guard (try? NotebookValidation.validate(object)) != nil else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { output in
            UIColor.white.setFill(); output.fill(CGRect(origin: .zero, size: size))
            let context = output.cgContext
            let scale = min((size.width - 28) / object.width, (size.height - 24) / object.height)
            context.translateBy(x: (size.width - object.width * scale) / 2 - object.x * scale,
                                y: (size.height - object.height * scale) / 2 - object.y * scale)
            context.scaleBy(x: scale, y: scale)
            ObjectRenderer.shared.draw(object, in: context)
        }
    }
}

struct CatalogThumbnail: View {
    var object: CanvasObject?
    var kind: String
    var cloud = false
    @State private var thumbnail: UIImage?
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit().padding(4)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: CatalogKind.icon(kind)).font(.system(size: 30, weight: .light)).foregroundStyle(.purple)
                    Text(kind == "widget" ? "Interactive object" : CatalogKind.title(kind)).font(.caption.weight(.medium))
                    Text(cloud && object == nil ? "Choose Preview to load" : "Preview after insertion")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task { thumbnail = object.flatMap { CatalogThumbnailRenderer.image(for: $0) } }
        .onChange(of: object) { _, value in thumbnail = value.flatMap { CatalogThumbnailRenderer.image(for: $0) } }
        .accessibilityLabel(thumbnail == nil ? "\(CatalogKind.title(kind)) preview placeholder" : "Object preview")
    }
}
