// AppMotionSystem.swift
// Shared motion, scroll settling, and image-work scheduling policy.
//
// This file is intentionally additive. Views can adopt one primitive at a time while
// existing behavior remains compatible. The policy types make decisions only; they do
// not fetch data or write state, preserving Stocked's local-first ownership model.

import SwiftUI

// MARK: - Motion tokens and Reduce Motion policy

/// The single semantic source of app animation timing.
///
/// Pick a token for the interaction's role instead of creating a page-local spring.
/// Reduce Motion is applied by ``StockedMotionPolicy`` rather than by each call site.
enum StockedMotion {
    enum Spring: String, CaseIterable, Sendable {
        /// Finger-down feedback and other tiny, reversible changes.
        case press
        /// Chips, steppers, and lightweight selections.
        case selection
        /// The default state-change spring.
        case standard
        /// Drawers, sheets, and navigation-adjacent transitions.
        case navigation
        /// Drag, resize, and reorder settling.
        case settle

        var response: Double {
            switch self {
            case .press:      return 0.18
            case .selection:  return 0.22
            case .standard:   return 0.30
            case .navigation: return 0.35
            case .settle:     return 0.38
            }
        }

        var dampingFraction: Double {
            switch self {
            case .press:      return 0.78
            case .selection:  return 0.82
            case .standard:   return 0.82
            case .navigation: return 0.85
            case .settle:     return 0.88
            }
        }

        var blendDuration: Double {
            switch self {
            case .press, .selection: return 0
            case .standard:          return 0.02
            case .navigation:        return 0.03
            case .settle:            return 0.04
            }
        }

        var animation: Animation {
            .spring(
                response: response,
                dampingFraction: dampingFraction,
                blendDuration: blendDuration
            )
        }
    }

    /// Describes what changes on screen so Reduce Motion can choose a safe fallback.
    enum Intent: Sendable {
        /// Position, scale, rotation, or geometry changes. Becomes instantaneous.
        case spatial
        /// An opacity-only transition. Retains a brief non-spatial fade.
        case opacity
        /// Nonessential flourish, bounce, pulse, or wiggle. Becomes instantaneous.
        case decorative
        /// Repeating or indefinite motion. Becomes instantaneous and must not repeat.
        case continuous
    }
}

/// A value read from the SwiftUI environment at the point an animation is applied.
struct StockedMotionPolicy: Equatable, Sendable {
    fileprivate(set) var reduceMotion: Bool = false

    init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }

    var permitsSpatialMotion: Bool { !reduceMotion }
    var permitsDecorativeMotion: Bool { !reduceMotion }
    var permitsContinuousMotion: Bool { !reduceMotion }

    /// Returns the requested spring, an opacity-only fallback, or `nil`.
    func animation(
        _ token: StockedMotion.Spring = .standard,
        intent: StockedMotion.Intent = .spatial
    ) -> Animation? {
        guard reduceMotion else { return token.animation }
        switch intent {
        case .opacity:
            return .linear(duration: 0.12)
        case .spatial, .decorative, .continuous:
            return nil
        }
    }

    /// Runs state changes with the same Reduce Motion behavior as ``animation(_:intent:)``.
    @MainActor
    @discardableResult
    func animate<Result>(
        _ token: StockedMotion.Spring = .standard,
        intent: StockedMotion.Intent = .spatial,
        _ changes: () throws -> Result
    ) rethrows -> Result {
        try withAnimation(animation(token, intent: intent), changes)
    }
}

private struct StockedMotionPolicyKey: EnvironmentKey {
    static let defaultValue = StockedMotionPolicy()
}

extension EnvironmentValues {
    /// Always folds the live system Reduce Motion value into the shared policy.
    var stockedMotion: StockedMotionPolicy {
        get {
            var policy = self[StockedMotionPolicyKey.self]
            policy.reduceMotion = accessibilityReduceMotion
            return policy
        }
        set { self[StockedMotionPolicyKey.self] = newValue }
    }
}

private struct StockedAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.stockedMotion) private var motion

    let token: StockedMotion.Spring
    let intent: StockedMotion.Intent
    let value: Value

    func body(content: Content) -> some View {
        content.animation(motion.animation(token, intent: intent), value: value)
    }
}

extension View {
    /// Applies a semantic app spring and automatically respects Reduce Motion.
    func stockedAnimation<Value: Equatable>(
        _ token: StockedMotion.Spring = .standard,
        intent: StockedMotion.Intent = .spatial,
        value: Value
    ) -> some View {
        modifier(StockedAnimationModifier(token: token, intent: intent, value: value))
    }
}

// MARK: - Scroll bounce and target helpers

extension View {
    /// Bounces only when content is larger than its viewport.
    func stockedSizeAwareScrollBounce(_ axes: Axis.Set = .vertical) -> some View {
        scrollBounceBehavior(.basedOnSize, axes: axes)
    }

    /// Marks the direct children of a lazy stack as candidates for section or rail snapping.
    /// For a page-level scroll, apply this only to the stack of major sections, not every row.
    func stockedSnapTargetLayout() -> some View {
        scrollTargetLayout()
    }

    /// Gives page-level scrolling native, continuous deceleration.
    ///
    /// Major sections may still register targets for programmatic navigation and
    /// coach marks, but a slow drag must never be rounded to a section boundary.
    /// Paging and card alignment belong only on explicit horizontal carousels.
    func stockedSectionSnapping(
        axes: Axis.Set = .vertical,
        anchor: UnitPoint = .top
    ) -> some View {
        scrollBounceBehavior(.basedOnSize, axes: axes)
    }

    /// Settles a horizontal rail on one complete, leading-aligned card after a drag. Centering
    /// the first card required half-viewport insets and left a conspicuous empty column before
    /// every rail; a stable page gutter uses the canvas while preserving predictable settling.
    func stockedRailSnapping() -> some View {
        scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne, anchor: .leading))
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(.leading)
    }

    /// Settles on a complete chip/token while still allowing a fast swipe to
    /// traverse a long filter rail. Card carousels should use `stockedRailSnapping`.
    func stockedChipRailSnapping() -> some View {
        scrollTargetBehavior(.viewAligned(limitBehavior: .automatic))
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(.leading)
    }

    /// Uses viewport-sized paging while avoiding bounce when the content already fits.
    func stockedPageSnapping(_ axes: Axis.Set = .horizontal) -> some View {
        scrollTargetBehavior(.paging)
            .scrollBounceBehavior(.basedOnSize, axes: axes)
    }
}

// MARK: - Scroll phase awareness

/// A stable app-facing representation of SwiftUI's scroll phases.
enum StockedScrollPhase: String, Hashable, Sendable {
    case idle
    case tracking
    case interacting
    case decelerating
    case animating

    fileprivate init(_ phase: ScrollPhase) {
        switch phase {
        case .idle:         self = .idle
        case .tracking:     self = .tracking
        case .interacting:  self = .interacting
        case .decelerating: self = .decelerating
        case .animating:    self = .animating
        @unknown default:   self = .idle
        }
    }
}

/// Lightweight state a screen can keep in `@State` to coordinate expensive work with scrolling.
struct StockedScrollActivity: Equatable, Sendable {
    var phase: StockedScrollPhase
    var horizontalVelocity: CGFloat
    var verticalVelocity: CGFloat
    var transitionSequence: UInt

    static let idle = StockedScrollActivity(
        phase: .idle,
        horizontalVelocity: 0,
        verticalVelocity: 0,
        transitionSequence: 0
    )

    var isScrolling: Bool { phase != .idle }

    /// True while a finger or pointer is directly steering the scroll view.
    var isDirectInteraction: Bool {
        phase == .tracking || phase == .interacting
    }

    /// Decode, filtering, and new remote image work should pause in these phases.
    var shouldDeferExpensiveWork: Bool {
        phase == .tracking || phase == .interacting || phase == .animating
    }

    /// Visible work may resume as the scroll slows; speculative work should usually wait for idle.
    var mayLoadVisibleImages: Bool {
        phase == .idle || phase == .decelerating
    }

    var mayPrefetchRemoteImages: Bool { phase == .idle }

    func velocity(along axis: Axis) -> CGFloat {
        switch axis {
        case .horizontal: return horizontalVelocity
        case .vertical:   return verticalVelocity
        }
    }

    fileprivate func updating(to phase: ScrollPhase, velocity: CGVector?) -> Self {
        let nextPhase = StockedScrollPhase(phase)
        return StockedScrollActivity(
            phase: nextPhase,
            // Keep the last nonzero direction through the idle transition. Deferred
            // prefetch starts at idle, so clearing velocity here made look-ahead work
            // lose the direction of the gesture that requested it.
            horizontalVelocity: nextPhase == .idle ? horizontalVelocity : velocity?.dx ?? horizontalVelocity,
            verticalVelocity: nextPhase == .idle ? verticalVelocity : velocity?.dy ?? verticalVelocity,
            transitionSequence: transitionSequence &+ 1
        )
    }
}

private struct StockedScrollActivityKey: EnvironmentKey {
    static let defaultValue = StockedScrollActivity.idle
}

extension EnvironmentValues {
    /// Activity from the nearest page-level Stocked scroll container. Nested rails
    /// can track their own phase while grids and images inherit this value for free.
    var stockedScrollActivity: StockedScrollActivity {
        get { self[StockedScrollActivityKey.self] }
        set { self[StockedScrollActivityKey.self] = newValue }
    }
}

private struct StockedScrollActivityModifier: ViewModifier {
    @Binding var activity: StockedScrollActivity

    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, newPhase, context in
            let next = activity.updating(to: newPhase, velocity: context.velocity)
            if next != activity { activity = next }
        }
    }
}

private struct StockedScrollActivityObserverModifier: ViewModifier {
    @State private var activity = StockedScrollActivity.idle
    let action: (StockedScrollActivity) -> Void

    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, newPhase, context in
            let next = activity.updating(to: newPhase, velocity: context.velocity)
            if next != activity { activity = next }
            action(next)
        }
    }
}

private struct StockedTrackedScrollScopeModifier: ViewModifier {
    @Environment(\.stockedScrollActivity) private var parentActivity
    @State private var localActivity = StockedScrollActivity.idle

    private var effectiveActivity: StockedScrollActivity {
        if localActivity.isScrolling { return localActivity }
        if parentActivity.isScrolling { return parentActivity }
        return localActivity
    }

    func body(content: Content) -> some View {
        content
            .stockedTrackScrollActivity($localActivity)
            .environment(\.stockedScrollActivity, effectiveActivity)
    }
}

extension View {
    /// Tracks phase and velocity without adding geometry readers or preference churn.
    func stockedTrackScrollActivity(_ activity: Binding<StockedScrollActivity>) -> some View {
        modifier(StockedScrollActivityModifier(activity: activity))
    }

    /// Observes phase and velocity when a screen does not need to retain the state itself.
    func stockedOnScrollActivityChange(
        _ action: @escaping (StockedScrollActivity) -> Void
    ) -> some View {
        modifier(StockedScrollActivityObserverModifier(action: action))
    }

    /// Gives a standalone or nested ScrollView its own activity scope and injects that
    /// activity into image descendants. While the local view is idle, an actively
    /// scrolling parent remains visible so nested content never masks page-level motion.
    func stockedTrackedScrollScope() -> some View {
        modifier(StockedTrackedScrollScopeModifier())
    }
}

// MARK: - Velocity-aware snapping

/// Pure snapping math for widgets, custom drags, sliders, and non-ScrollView surfaces.
///
/// Coordinates use a simple contract: increasing offset and positive velocity move toward
/// later indexes. Callers with reversed coordinates should negate both values first.
struct StockedVelocitySnapPolicy: Equatable, Sendable {
    var velocityThreshold: CGFloat = 420
    var distanceThreshold: CGFloat = 0.28
    var projectionTime: CGFloat = 0.16
    var maximumIndexAdvance: Int = 1

    func targetIndex(
        currentIndex: Int,
        currentOffset: CGFloat,
        itemExtent: CGFloat,
        velocity: CGFloat,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0, itemExtent > 0 else { return 0 }
        let current = currentIndex.clamped(to: 0...(itemCount - 1))
        let projectedOffset = currentOffset + velocity * projectionTime
        let progress = (projectedOffset / itemExtent) - CGFloat(current)

        var advance = 0
        if abs(velocity) >= velocityThreshold {
            let projectedIndex = Int((projectedOffset / itemExtent).rounded())
            let projectedAdvance = projectedIndex - current
            advance = projectedAdvance == 0 ? (velocity > 0 ? 1 : -1) : projectedAdvance
        } else if progress >= distanceThreshold {
            advance = 1
        } else if progress <= -distanceThreshold {
            advance = -1
        }

        let boundedAdvance = advance.clamped(
            to: -max(1, maximumIndexAdvance)...max(1, maximumIndexAdvance)
        )
        return (current + boundedAdvance).clamped(to: 0...(itemCount - 1))
    }

    func targetOffset(
        currentIndex: Int,
        currentOffset: CGFloat,
        itemExtent: CGFloat,
        velocity: CGFloat,
        itemCount: Int,
        leadingInset: CGFloat = 0
    ) -> CGFloat {
        CGFloat(targetIndex(
            currentIndex: currentIndex,
            currentOffset: currentOffset,
            itemExtent: itemExtent,
            velocity: velocity,
            itemCount: itemCount
        )) * itemExtent + leadingInset
    }

    /// Quantizes a scalar to a magnetic grid and clamps it to valid bounds.
    func magneticValue(
        _ value: CGFloat,
        increment: CGFloat,
        origin: CGFloat = 0,
        bounds: ClosedRange<CGFloat>? = nil
    ) -> CGFloat {
        guard increment > 0 else { return bounds.map { value.clamped(to: $0) } ?? value }
        let snapped = ((value - origin) / increment).rounded() * increment + origin
        return bounds.map { snapped.clamped(to: $0) } ?? snapped
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - Image deferral and prefetch policy

/// The source already selected by the feature's provenance and fallback rules.
/// This policy never changes that source order; it only schedules the work.
enum StockedImageWorkSource: Equatable, Sendable {
    /// Decoded and immediately displayable.
    case memory
    /// Embedded bytes or an on-disk cache entry that still requires decode.
    case localEncoded
    /// A source that requires connectivity before decode.
    case remote
}

enum StockedImageWorkPurpose: Sendable {
    case visible
    case prefetch
}

enum StockedImageWorkPriority: Equatable, Sendable {
    case userInitiated
    case utility
    case background

    var taskPriority: TaskPriority {
        switch self {
        case .userInitiated: return .userInitiated
        case .utility:       return .utility
        case .background:    return .background
        }
    }
}

enum StockedImageWorkDirective: Equatable, Sendable {
    case displayNow
    case loadNow(priority: StockedImageWorkPriority)
    case deferUntilDeceleration
    case deferUntilIdle
    /// The caller should keep its local placeholder/fallback; no request is started.
    case localOnly
}

struct StockedImageWorkRequest: Sendable {
    var source: StockedImageWorkSource
    var purpose: StockedImageWorkPurpose

    init(source: StockedImageWorkSource, purpose: StockedImageWorkPurpose) {
        self.source = source
        self.purpose = purpose
    }
}

/// Shared scheduling policy for image pipelines. It is deliberately unaware of URLSession
/// and ImageCache, so offline and local data remain authoritative at the feature boundary.
struct StockedImageWorkPolicy: Equatable, Sendable {
    /// Brief idle debounce callers can use before starting a speculative batch.
    var idleDebounce: TimeInterval = 0.12
    var maximumPrefetchBatchSize: Int = 12
    var lookAheadCount: Int = 6
    var lookBehindCount: Int = 2

    func directive(
        for request: StockedImageWorkRequest,
        activity: StockedScrollActivity,
        remoteAccessAllowed: Bool
    ) -> StockedImageWorkDirective {
        if request.source == .memory { return .displayNow }
        if request.source == .remote && !remoteAccessAllowed { return .localOnly }

        switch request.purpose {
        case .visible:
            switch activity.phase {
            case .idle, .decelerating:
                return .loadNow(priority: .userInitiated)
            case .tracking, .interacting:
                return .deferUntilDeceleration
            case .animating:
                return .deferUntilIdle
            }

        case .prefetch:
            switch activity.phase {
            case .idle:
                return .loadNow(priority: request.source == .remote ? .utility : .background)
            case .decelerating:
                return request.source == .localEncoded
                    ? .loadNow(priority: .background)
                    : .deferUntilIdle
            case .tracking, .interacting, .animating:
                return .deferUntilIdle
            }
        }
    }

    /// Returns a bounded, nearest-first list of indexes around the visible window.
    /// Positive velocity looks ahead toward later indexes; negative velocity looks earlier.
    func candidateIndices(
        itemCount: Int,
        visibleRange: Range<Int>,
        axis: Axis,
        activity: StockedScrollActivity,
        excluding availableIndices: Set<Int> = []
    ) -> [Int] {
        guard itemCount > 0, !visibleRange.isEmpty, maximumPrefetchBatchSize > 0 else { return [] }

        let lower = visibleRange.lowerBound.clamped(to: 0...(itemCount - 1))
        let upperExclusive = visibleRange.upperBound.clamped(to: 0...itemCount)
        let velocity = activity.velocity(along: axis)
        let movingBackward = velocity < -24

        let after = indexes(
            from: upperExclusive,
            toward: min(itemCount, upperExclusive + max(0, lookAheadCount)),
            ascending: true
        )
        let before = indexes(
            from: lower - 1,
            toward: max(-1, lower - max(0, lookBehindCount) - 1),
            ascending: false
        )
        let ordered = movingBackward ? before + after : after + before
        return Array(ordered.lazy
            .filter { $0 >= 0 && $0 < itemCount && !availableIndices.contains($0) }
            .prefix(maximumPrefetchBatchSize))
    }

    private func indexes(from start: Int, toward end: Int, ascending: Bool) -> [Int] {
        if ascending {
            guard start < end else { return [] }
            return Array(start..<end)
        }
        guard start > end else { return [] }
        return Array(stride(from: start, to: end, by: -1))
    }
}
