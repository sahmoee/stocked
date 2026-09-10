import SwiftUI

/// A lazy collection of equal-height rows. Only siblings share a height, so one
/// long card cannot stretch an entire catalogue or leave cards floating mid-row.
struct StockedEqualHeightGrid<Item, ID: Hashable, Content: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let columns: Int
    let spacing: CGFloat
    let content: (Item) -> Content

    init(items: [Item], id: KeyPath<Item, ID>, columns: Int, spacing: CGFloat = 12,
         @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.id = id
        self.columns = max(1, columns)
        self.spacing = max(0, spacing)
        self.content = content
    }

    init(items: [Item], columns: Int, spacing: CGFloat = 12,
         @ViewBuilder content: @escaping (Item) -> Content) where Item: Identifiable, ID == Item.ID {
        self.init(items: items, id: \.id, columns: columns, spacing: spacing, content: content)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                StockedEqualHeightRow(columns: columns, spacing: spacing) {
                    ForEach(Array(items[start..<min(start + columns, items.count)]), id: id) { item in
                        content(item)
                    }
                }
            }
        }
    }
}

