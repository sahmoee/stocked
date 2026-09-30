import SwiftUI

/// App adapters supply their existing semantic tokens; this owns geometry only.
public struct SowensSurface<Fill: ShapeStyle>: ViewModifier {
    let fill: Fill
    let border: Color
    let radius: CGFloat
    let lineWidth: CGFloat
    let clipsContent: Bool

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if clipsContent { content.background(fill, in: shape).clipShape(shape) }
            else { content.background(fill, in: shape) }
        }
        .overlay { shape.strokeBorder(border, lineWidth: lineWidth).allowsHitTesting(false) }
    }
}

extension View {
    public func sowensSurface<Fill: ShapeStyle>(fill: Fill, border: Color = .clear, radius: CGFloat = 18,
                                               lineWidth: CGFloat = 1, clipsContent: Bool = false) -> some View {
        modifier(SowensSurface(fill: fill, border: border, radius: radius, lineWidth: lineWidth, clipsContent: clipsContent))
    }
}

/// Reusable accessible status content. The hosting app owns its background and actions.
public struct SowensStatusView: View {
    public enum State: Sendable { case empty, loading, offline, failed }
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String
    let state: State

    public init(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, state: State = .empty) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 12) {
            if state == .loading { ProgressView().accessibilityLabel(title) }
            else { Image(systemName: symbol).font(.largeTitle).accessibilityHidden(true) }
            Text(title).font(.headline)
            Text(detail).font(.body).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// Fixture identity shared by image tests; invalid URLs never become network requests.
public enum PhotoInput: Equatable, Sendable {
    case embedded(Data)
    case remote(URL)
    case missing

    public static func resolve(data: Data?, url: String?) -> Self {
        if let data, !data.isEmpty { return .embedded(data) }
        guard let raw = url, let value = URL(string: raw),
              ["http", "https"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil else { return .missing }
        return .remote(value)
    }
}
