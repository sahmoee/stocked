// QAFloatingOverlay.swift — the always-accessible floating QA panel, mounted at
// the app root. Presented full when opened; minimizes to a draggable bubble.
// While the bubble is dragged, a "Close & Sync" drop zone appears at the bottom;
// releasing over it saves + syncs and closes.

import SwiftUI

struct QAFloatingOverlay: View {
    @Environment(AppSession.self) private var session
    private var qa = QAWorkbookStore.shared
    @State private var dragging = false
    @State private var dragOffset: CGSize = .zero
    @State private var overZone = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if qa.isPresented && !qa.isMinimized {
                    Color.black.opacity(0.28).ignoresSafeArea()
                        .onTapGesture { qa.minimize() }
                    QAWorkbookPanel()
                        .environment(session)
                        .frame(maxWidth: 640)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 26, y: 10)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 34)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if qa.isPresented && qa.isMinimized {
                    if dragging { dropZone(geo) }
                    bubble(geo)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: qa.isPresented)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: qa.isMinimized)
        }
        .ignoresSafeArea(.keyboard)
        // Shake-to-report from anywhere (only when QA is unlocked, so normal users never trigger it).
        .background(qa.unlocked ? AnyView(Color.clear.qaShakeToReport()) : AnyView(EmptyView()))
        // Quick-report sheet (screenshot + auto-context) fired by shake or long-pressing the bubble.
        .sheet(isPresented: Binding(get: { qa.showQuickReport }, set: { qa.showQuickReport = $0 })) {
            if let id = qa.quickReportID { QuickReportSheet(changeID: id) }
        }
    }

    // MARK: Minimized bubble

    private func basePoint(_ geo: GeometryProxy) -> CGPoint {
        CGPoint(x: geo.size.width - 54, y: geo.size.height - 150)
    }

    private func bubble(_ geo: GeometryProxy) -> some View {
        let base = basePoint(geo)
        let x = base.x + qa.bubbleOffset.width + dragOffset.width
        let y = base.y + qa.bubbleOffset.height + dragOffset.height
        return bubbleLabel
            .position(x: min(max(40, x), geo.size.width - 40),
                      y: min(max(60, y), geo.size.height - 40))
            .onTapGesture { if !dragging { qa.expand() } }
            .onLongPressGesture(minimumDuration: 0.5) { qa.startQuickReport() }  // long-press → quick capture
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        dragging = true
                        dragOffset = v.translation
                        let ry = base.y + qa.bubbleOffset.height + v.translation.height
                        let rx = base.x + qa.bubbleOffset.width + v.translation.width
                        overZone = ry > geo.size.height - 130 && abs(rx - geo.size.width / 2) < 130
                    }
                    .onEnded { v in
                        if overZone {
                            qa.closeAndSync(store: session.guestStore)
                        } else {
                            var w = qa.bubbleOffset.width + v.translation.width
                            var h = qa.bubbleOffset.height + v.translation.height
                            // Keep it reachable on screen.
                            w = min(max(w, -(geo.size.width - 100)), 20)
                            h = min(max(h, -(geo.size.height - 200)), 100)
                            qa.bubbleOffset = CGSize(width: w, height: h)
                        }
                        dragOffset = .zero; dragging = false; overZone = false
                    }
            )
    }

    private var bubbleLabel: some View {
        VStack(spacing: 1) {
            Text("QA").font(QATheme.serif(15)).foregroundStyle(.white)
            Text("\(Int(qa.overallProgress() * 100))%").font(QATheme.sans(9, .bold)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 56, height: 56)
        .background(Circle().fill(QATheme.brown))
        .overlay(Circle().stroke(QATheme.card, lineWidth: 2))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .scaleEffect(dragging ? 1.08 : 1)
    }

    // MARK: Drag-to-close/sync drop zone (only while dragging)

    private func dropZone(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 6) {
            Image(systemName: overZone ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(overZone ? .white : QATheme.brown)
            Text("Close & Sync").font(QATheme.sans(12, .bold))
                .foregroundStyle(overZone ? .white : QATheme.brown)
        }
        .frame(width: 190, height: 92)
        .background(RoundedRectangle(cornerRadius: 20).fill(overZone ? QATheme.pass : QATheme.tan.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(QATheme.brown.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .scaleEffect(overZone ? 1.06 : 1)
        .position(x: geo.size.width / 2, y: geo.size.height - 70)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}
