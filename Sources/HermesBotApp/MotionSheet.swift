import AppKit
import SwiftUI

// Window-modal sheet whose presentation follows the motion gate.
//
// SwiftUI's `.sheet` on macOS always runs the AppKit slide + parent dimmer fade: a no-animation
// `Transaction` does not reach it. This presenter runs the same AppKit sheet (`beginSheet`/`endSheet`)
// itself: with motion on it is the unchanged system transition; with motion off both calls run inside a
// zero-duration `NSAnimationContext`, so the sheet and the dimmer appear and disappear in one frame.

/// How a sheet transition runs for a motion gate value.
enum SheetTransition {
    /// Motion on: the system slide and dimmer fade. Motion off: one frame, no slide, no fade.
    @MainActor static func run(motion: Bool, _ body: () -> Void) {
        guard !motion else { return body() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            body()
        }, completionHandler: nil)
    }
}

extension View {
    /// `.sheet(isPresented:)` for the create-room form, gated by `motion` (the resolved motion gate).
    /// The content gets its own hosting controller, so environment the sheet needs (motion gate, tint)
    /// is applied here rather than inherited.
    func motionSheet<Sheet: View>(isPresented: Binding<Bool>, motion: Bool,
                                  @ViewBuilder content: @escaping () -> Sheet) -> some View {
        background(MotionSheetHost(isPresented: isPresented, motion: motion, content: content))
    }
}

private struct MotionSheetHost<Sheet: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let motion: Bool
    let content: () -> Sheet

    func makeCoordinator() -> MotionSheetCoordinator { MotionSheetCoordinator() }

    func makeNSView(context: Context) -> SheetAnchorView {
        let view = SheetAnchorView()
        let coordinator = context.coordinator
        view.onWindow = { [weak coordinator] in coordinator?.schedule() }
        return view
    }

    func updateNSView(_ view: SheetAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchor = view
        coordinator.binding = $isPresented
        coordinator.motion = motion
        coordinator.content = AnyView(content().environment(\.motionEnabled, motion).tint(DS.Palette.primary))
        coordinator.schedule()
    }

    static func dismantleNSView(_ view: SheetAnchorView, coordinator: MotionSheetCoordinator) {
        coordinator.tearDown()
    }
}

final class SheetAnchorView: NSView {
    var onWindow: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?()
    }
}

/// Owns the sheet window. `beginSheet`/`endSheet` block the main thread for the length of the
/// transition, so they never run inside a SwiftUI update: `schedule()` defers to the next main-queue turn.
@MainActor final class MotionSheetCoordinator {
    weak var anchor: NSView?
    var binding: Binding<Bool>?
    var motion = true
    var content = AnyView(EmptyView())

    private(set) var sheet: NSWindow?
    private var host: NSHostingController<AnyView>?
    private weak var parent: NSWindow?
    private var scheduled = false

    func schedule() {
        host?.rootView = content
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.sync()
        }
    }

    private func sync() {
        let wanted = binding?.wrappedValue ?? false
        if wanted, sheet == nil {
            guard let window = anchor?.window, window.attachedSheet == nil else { return }
            present(on: window)
        } else if !wanted, let sheet, let parent {
            // Forget it first: the begin completion handler then sees a different sheet and does nothing.
            self.sheet = nil
            host = nil
            SheetTransition.run(motion: motion) { parent.endSheet(sheet) }
        }
    }

    private func present(on window: NSWindow) {
        let host = NSHostingController(rootView: content)
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled]
        sheet.appearance = window.appearance
        self.host = host
        self.sheet = sheet
        self.parent = window
        SheetTransition.run(motion: motion) {
            window.beginSheet(sheet) { [weak self] _ in
                // Ended by endSheet (binding went false) or by AppKit (window closing): forget the sheet
                // and make sure the binding agrees, outside the current update.
                guard let self, self.sheet === sheet else { return }
                self.sheet = nil
                self.host = nil
                if self.binding?.wrappedValue == true {
                    DispatchQueue.main.async { self.binding?.wrappedValue = false }
                }
            }
        }
    }

    func tearDown() {
        guard let sheet, let parent else { return }
        self.sheet = nil
        host = nil
        SheetTransition.run(motion: false) { parent.endSheet(sheet) }
    }
}
