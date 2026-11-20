import Foundation
import Testing
@testable import Endless_Drawing

struct FingerGestureTests {
    @Test func oneFingerDraws() {
        var gesture = FingerGesture()
        #expect(gesture.began(id: 1, at: 10) == .draw(1))
        #expect(gesture.drawing == 1)
        gesture.ended(id: 1)
        #expect(gesture.drawing == nil)
        #expect(gesture.began(id: 2, at: 11) == .draw(2))
    }

    /// Two fingers that land almost together are a pinch: the started stroke is abandoned.
    @Test func quickSecondFingerTurnsStrokeIntoNavigation() {
        var gesture = FingerGesture()
        _ = gesture.began(id: 1, at: 10)
        #expect(gesture.began(id: 2, at: 10 + FingerGesture.pinchGrace / 2) == .navigate([1, 2]))
        #expect(gesture.drawing == nil)
        #expect(gesture.navigating)
        #expect(gesture.began(id: 3, at: 11) == .navigate([3])) // NavigationInput decides about a third finger
        gesture.ended(id: 1)
        #expect(gesture.navigating) // until every finger lifts
        gesture.ended(id: 2); gesture.ended(id: 3)
        #expect(!gesture.navigating)
        #expect(gesture.began(id: 4, at: 12) == .draw(4))
    }

    /// A resting finger during a stroke in progress must neither cancel it nor move the canvas.
    @Test func lateSecondFingerIsIgnored() {
        var gesture = FingerGesture()
        _ = gesture.began(id: 1, at: 10)
        #expect(gesture.began(id: 2, at: 10 + FingerGesture.pinchGrace + 0.1) == .none)
        #expect(gesture.drawing == 1)
        gesture.ended(id: 1)
        // The leftover finger does not start a new stroke, and neither does another one beside it.
        #expect(gesture.began(id: 3, at: 11) == .none)
        gesture.ended(id: 2); gesture.ended(id: 3)
        #expect(gesture.began(id: 4, at: 12) == .draw(4))
    }

    @Test func abandonedDrawingIgnoresRemainingFingers() {
        var gesture = FingerGesture()
        _ = gesture.began(id: 1, at: 10)
        gesture.abandonDrawing() // Pencil took over, or the palette opened
        #expect(gesture.began(id: 2, at: 10.05) == .none)
        gesture.ended(id: 1); gesture.ended(id: 2)
        #expect(gesture.began(id: 3, at: 11) == .draw(3))
    }

    @Test func policyPrefersExplicitChoiceThenPencil() {
        #expect(FingerDrawingPolicy.fingersDraw(choice: nil, pencilSeen: false, systemPencilOnly: false))
        #expect(!FingerDrawingPolicy.fingersDraw(choice: nil, pencilSeen: true, systemPencilOnly: false))
        #expect(!FingerDrawingPolicy.fingersDraw(choice: nil, pencilSeen: false, systemPencilOnly: true))
        #expect(FingerDrawingPolicy.fingersDraw(choice: true, pencilSeen: true, systemPencilOnly: true))
        #expect(!FingerDrawingPolicy.fingersDraw(choice: false, pencilSeen: false, systemPencilOnly: false))
    }

    @MainActor @Test func firstPencilSwitchesAutomaticModeAndPersists() throws {
        let name = "FingerGestureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CanvasModel(defaults: defaults)
        let before = model.fingersDraw
        model.pencilUsed()
        #expect(!model.fingersDraw)
        #expect(model.notice != nil || !before) // told once, only when fingers actually stopped drawing
        let relaunched = CanvasModel(defaults: defaults)
        #expect(relaunched.pencilSeen)
        #expect(!relaunched.fingersDraw)
        relaunched.setFingerDrawing(true)
        relaunched.pencilUsed()
        #expect(relaunched.notice == nil)
        #expect(CanvasModel(defaults: defaults).fingersDraw) // the explicit choice survives a relaunch
    }
}
