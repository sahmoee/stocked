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
struct CollectionGrid<Item: Hashable & Sendable, Cell: View>: UIViewRepresentable {
    var items: [Item]
    var columns: Int = 2
    var interItemSpacing: CGFloat = 12
    var lineSpacing: CGFloat = 12
    var contentInsets: NSDirectionalEdgeInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
    var onSelect: @MainActor (Item) -> Void = { _ in }
    var onVerticalCollapseChange: @MainActor (Bool) -> Void = { _ in }
    @ViewBuilder var cell: (Item) -> Cell

    // Non-isolated so its synthesized Hashable/Sendable conformance can satisfy
    // NSDiffableDataSourceSnapshot's requirement. Nested in the @MainActor
    // Coordinator it became main-actor-isolated, which Swift 6 rejects.
    nonisolated enum Section: Hashable, Sendable { case main }

    func makeCoordinator() -> Coordinator {
        Coordinator(cell: cell, onSelect: onSelect,
                    onVerticalCollapseChange: onVerticalCollapseChange)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = context.coordinator.makeLayout(columns: columns,
                                                     interItemSpacing: interItemSpacing,
                                                     lineSpacing: lineSpacing,
                                                     contentInsets: contentInsets)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.bounces = true
        collectionView.alwaysBounceVertical = false
        collectionView.delegate = context.coordinator
        context.coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        context.coordinator.configureDataSource(for: collectionView)
        context.coordinator.apply(items, animated: false)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.cell = cell
        context.coordinator.onSelect = onSelect
        context.coordinator.onVerticalCollapseChange = onVerticalCollapseChange
        context.coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        context.coordinator.apply(
            items,
            animated: !context.environment.accessibilityReduceMotion
                && !collectionView.isDragging
                && !collectionView.isDecelerating
        )
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var cell: (Item) -> Cell
        var onSelect: (Item) -> Void
        var onVerticalCollapseChange: (Bool) -> Void
        var reduceMotion = false
        private var scrollActivity = StockedScrollActivity.idle
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
        private var headerIsCollapsed = false

        init(cell: @escaping (Item) -> Cell, onSelect: @escaping (Item) -> Void,
             onVerticalCollapseChange: @escaping (Bool) -> Void) {
            self.cell = cell
            self.onSelect = onSelect
            self.onVerticalCollapseChange = onVerticalCollapseChange
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
            self.collectionView = collectionView
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cellView, _, item in
                guard let self else { return }
                cellView.contentConfiguration = UIHostingConfiguration {
                    self.cell(item)
                        .environment(\.stockedScrollActivity, self.scrollActivity)
                }
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
            collectionView.deselectItem(at: indexPath, animated: !reduceMotion)
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            onSelect(item)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            setScrollActivity(.tracking)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let collapsed = scrollView.contentOffset.y > 24
            guard collapsed != headerIsCollapsed else { return }
            headerIsCollapsed = collapsed
            onVerticalCollapseChange(collapsed)
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            setScrollActivity(
                .decelerating,
                horizontalVelocity: velocity.x,
                verticalVelocity: velocity.y
            )
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { setScrollActivity(.idle) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            setScrollActivity(.idle)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            setScrollActivity(.idle)
        }

        /// Reconfigure hosted cells only at scroll phase boundaries—not per pixel—so
        /// image tasks receive cancellation/resume signals without adding scroll churn.
        private func setScrollActivity(
            _ phase: StockedScrollPhase,
            horizontalVelocity: CGFloat = 0,
            verticalVelocity: CGFloat = 0
        ) {
            guard phase != scrollActivity.phase
                    || horizontalVelocity != scrollActivity.horizontalVelocity
                    || verticalVelocity != scrollActivity.verticalVelocity else { return }
            scrollActivity = StockedScrollActivity(
                phase: phase,
                horizontalVelocity: horizontalVelocity == 0
                    ? scrollActivity.horizontalVelocity
                    : horizontalVelocity,
                verticalVelocity: verticalVelocity == 0
                    ? scrollActivity.verticalVelocity
                    : verticalVelocity,
                transitionSequence: scrollActivity.transitionSequence &+ 1
            )
            guard let dataSource, let collectionView else { return }
            let visibleItems = collectionView.indexPathsForVisibleItems.compactMap {
                dataSource.itemIdentifier(for: $0)
            }
            guard !visibleItems.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visibleItems)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }
}
