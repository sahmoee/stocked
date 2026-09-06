// SwipeToDelete.swift — a reusable swipe-to-delete affordance for rows that live in a
// ScrollView + LazyVStack rather than a SwiftUI List. The inventory and grocery screens
// build their rows by hand (for custom cards, drag-and-drop, split panes), so the List-only
// `.swipeActions` modifier is unavailable. This wraps any row content and reveals a red
// Delete action when the user drags left, matching the platform gesture while keeping the
// custom card look.
//
// Usage:
//   MyRowCard()
//       .swipeToDelete { store.remove(id) }
//
// Behavior:
//   • Drag left to reveal the Delete button; tap it, or drag far enough and release, to fire.
//   • Springs back if the drag is short or the user swipes right.
//   • Only one row stays open at a time is NOT enforced here (each row is independent); rows
//     close themselves on action. This keeps the component dependency-free and cheap.
import SwiftUI

struct SwipeToDeleteModifier: ViewModifier {
    @Environment(\.stockedMotion) private var motion
    let confirmTitle: String?
    let onDelete: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var showConfirm = false

    // Width of the revealed action zone, and how far the user must drag to auto-trigger.
    private let actionWidth: CGFloat = 84
    private let triggerThreshold: CGFloat = 160

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            // Red delete track behind the row.
            HStack {
                Spacer()
                Button {
                    fire()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash.fill").scaledFont(16, weight: .semibold)
                        Text("Delete").scaledFont(11, weight: .semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
                .opacity(offsetX < -4 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

            // The row itself, shifted by the drag.
            content
                .offset(x: offsetX)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 18, coordinateSpace: .local)
                        .onChanged { value in
                            // Only respond to a mostly-horizontal leftward drag so vertical
                            // scrolling and the calendar drag stay responsive.
                            guard value.translation.width < 0,
                                  abs(value.translation.width) > abs(value.translation.height) else { return }
                            offsetX = max(value.translation.width, -actionWidth - 40)
                        }
                        .onEnded { value in
                            let projected = min(0, value.predictedEndTranslation.width)
                            if projected < -triggerThreshold {
                                fire()
                            } else {
                                let target = StockedVelocitySnapPolicy().magneticValue(
                                    projected,
                                    increment: actionWidth,
                                    bounds: -actionWidth...0
                                )
                                motion.animate(.settle, intent: .spatial) { offsetX = target }
                            }
                        }
                )
        }
        .confirmationDialog(confirmTitle ?? "", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commit() }
            Button("Cancel", role: .cancel) {
                motion.animate(.settle, intent: .spatial) { offsetX = 0 }
            }
        }
    }

    private func fire() {
        HapticManager.warning()
        if confirmTitle != nil {
            showConfirm = true
        } else {
            commit()
        }
    }

    private func commit() {
        motion.animate(.settle, intent: .spatial) { offsetX = -500 }
        // Let the row slide off before the data mutation animates the collapse.
        Task { @MainActor in
            if motion.permitsSpatialMotion {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            onDelete()
            offsetX = 0
        }
    }
}

extension View {
    /// Adds a leftward swipe-to-delete affordance. Pass `confirmTitle` to require a
    /// confirmation dialog before deleting; omit it for an immediate (ideally undoable) delete.
    func swipeToDelete(confirmTitle: String? = nil, perform onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(confirmTitle: confirmTitle, onDelete: onDelete))
    }
}
