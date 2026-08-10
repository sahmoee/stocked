import SwiftUI
import UIKit

/// UIKit bridge: high density scrolling backed by UICollectionView with a
/// compositional layout and a diffable data source, rendering SwiftUI cells
/// through UIHostingConfiguration.
/// Best fit UIKit area two: large inventory and recipe collections where
/// List and LazyVGrid recompute too much.
///
/// Item must be Hashable and stable so the diffable data source can track it.
@available(iOS 16.0, *)
struct CollectionGrid<Item: Hashable, Cell: View>: UIViewRepresentable {
    var items: [Item]
    var columns: Int = 2
    var interItemSpacing: CGFloat = 12
    var lineSpacing: CGFloat = 12
    var contentInsets: NSDirectionalEdgeInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
    var onSelect: @MainActor (Item) -> Void = { _ in }
    @ViewBuilder var cell: (Item) -> Cell

    func makeCoordinator() -> Coordinator {
        Coordinator(cell: cell, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = context.coordinator.makeLayout(columns: columns,
                                                     interItemSpacing: interItemSpacing,
                                                     lineSpacing: lineSpacing,
                                                     contentInsets: contentInsets)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = context.coordinator
        context.coordinator.configureDataSource(for: collectionView)
        context.coordinator.apply(items, animated: false)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.cell = cell
        context.coordinator.onSelect = onSelect
        context.coordinator.apply(items, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        enum Section { case main }

        var cell: (Item) -> Cell
        var onSelect: (Item) -> Void
        private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?

        init(cell: @escaping (Item) -> Cell, onSelect: @escaping (Item) -> Void) {
            self.cell = cell
            self.onSelect = onSelect
        }

        func makeLayout(columns: Int,
                        interItemSpacing: CGFloat,
                        lineSpacing: CGFloat,
                        contentInsets: NSDirectionalEdgeInsets) -> UICollectionViewLayout {
            let count = max(1, columns)
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .estimated(180))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                   heightDimension: .estimated(180))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize,
                                                           repeatingSubitem: item,
                                                           count: count)
            group.interItemSpacing = .fixed(interItemSpacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = lineSpacing
            section.contentInsets = contentInsets
            return UICollectionViewCompositionalLayout(section: section)
        }

        func configureDataSource(for collectionView: UICollectionView) {
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cellView, _, item in
                guard let self else { return }
                cellView.contentConfiguration = UIHostingConfiguration { self.cell(item) }
                    .margins(.all, 0)
                cellView.backgroundColor = .clear
            }
            dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { view, indexPath, item in
                view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
            }
        }

        func apply(_ items: [Item], animated: Bool) {
            guard let dataSource else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            snapshot.appendSections([.main])
            snapshot.appendItems(items, toSection: .main)
            dataSource.apply(snapshot, animatingDifferences: animated)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            onSelect(item)
        }
    }
}
