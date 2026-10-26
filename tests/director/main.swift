import Foundation

var checks = 0
func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { fatalError("FAIL: " + label) }
    print("PASS: " + label)
}
func fixture() -> DirectorInput {
    var observation = DirectorObservation()
    observation.subject = DirectorBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    observation.subjectKind = "body"
    observation.personCount = 1
    observation.confidence = 0.9
    observation.sharpness = 85
    return DirectorInput(observation: observation, scene: "人物", sceneConfidence: 0.9,
                         zoom: 1, minimumZoom: 0.5, maximumZoom: 20, nativeMaximumZoom: 3,
                         stable: true, framing: "自动", composition: "自动", preference: nil)
}
var input = fixture()
expect(DirectorEngine.evaluate(input).targetZoom > 1, "A small centered body can trigger an incremental zoom-in")
input.observation.subjectKind = "face"
input.observation.subject = DirectorBox(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
expect(DirectorEngine.evaluate(input).targetZoom < 1, "A large face is not mistaken for a small whole body")
input = fixture(); input.stable = false
expect(!DirectorEngine.evaluate(input).shouldZoom, "Shake prevents automatic zoom")
input = fixture(); input.observation.subject = nil
expect(!DirectorEngine.evaluate(input).shouldZoom, "No subject means no automatic zoom")
input = fixture(); input.observation.confidence = 0.2
expect(!DirectorEngine.evaluate(input).shouldZoom, "Low-confidence boxes cannot drive the lens")
input = fixture(); input.observation.personCount = 3; input.observation.subjectKind = "group"
input.observation.subject = DirectorBox(x: 0.01, y: 0.12, width: 0.98, height: 0.78)
expect(DirectorEngine.evaluate(input).targetZoom < 1, "A group near both edges zooms out instead of cutting people off")
input = fixture(); input.observation.brightness = 0.1
expect(DirectorEngine.evaluate(input).targetZoom <= 1, "Darkness prevents zoom-in")
input = fixture(); input.observation.sharpness = 30
expect(DirectorEngine.evaluate(input).targetZoom <= 1, "Low detail prevents zoom-in")
input = fixture(); input.observation.highlights = 0.15
expect(DirectorEngine.evaluate(input).exposureBias < 0, "Clipped highlights request bounded negative exposure compensation")
input = fixture(); input.observation.saturation = 0.8
expect(DirectorEngine.evaluate(input).filter == "自然", "Already saturated skin does not get another vivid preset")
expect(DirectorEngine.evaluate(input).maximumFilterStrength <= 0.4, "Strong saturation reduces filter strength")
input = fixture(); input.observation.personCount = 0; input.sceneConfidence = 0.2
expect(DirectorEngine.evaluate(input).filter == "自然", "Unknown scene preserves a natural filter")
input = fixture(); input.minimumZoom = 0.5; input.maximumZoom = 0.75; input.zoom = 1
let bounded = DirectorEngine.evaluate(input)
expect(bounded.targetZoom >= 0.5 && bounded.targetZoom <= 0.75, "A shrinking hardware range clamps a stale zoom reading")
for minimum in [0.5, 1.0, 2.0] {
    for maximum in [2.0, 5.0, 20.0] where maximum >= minimum {
        for zoom in [0.2, 0.5, 1.0, 4.0, 30.0] {
            input = fixture(); input.minimumZoom = minimum; input.maximumZoom = maximum; input.zoom = zoom
            let d = DirectorEngine.evaluate(input)
            expect(d.targetZoom.isFinite && d.targetZoom >= minimum && d.targetZoom <= maximum, "Decision remains inside live hardware bounds")
        }
    }
}
var controller = DirectorController()
input = fixture()
for i in 0..<3 {
    expect(!controller.evaluate(input, now: Double(i) * 0.21, allowAutomaticZoom: true).shouldZoom, "Initial observations must dwell before a lens command")
}
expect(controller.evaluate(input, now: 0.63, allowAutomaticZoom: true).shouldZoom, "Four consistent observations permit a command")
for i in 4...8 {
    expect(!controller.evaluate(input, now: Double(i) * 0.21, allowAutomaticZoom: true).shouldZoom, "Cooldown prevents repeated commands while the lens settles")
}
expect(!controller.evaluate(input, now: 2.1, allowAutomaticZoom: false).shouldZoom, "Manual takeover suppresses automatic commands")
input.observation.subject = nil
expect(!controller.evaluate(input, now: 2.31, allowAutomaticZoom: true).shouldZoom, "Losing the subject stops lens commands")
input = fixture()
expect(!controller.evaluate(input, now: 2.52, allowAutomaticZoom: true).shouldZoom, "Reacquisition requires a new dwell period")

var preference = DirectorPreference()
let context = DirectorLearningContext(scene: "人物", kind: "body", group: false, subjectFraction: 0.5, automaticFraming: true)
preference.learn(context: context, filter: "胶片", strength: 0.6, framingFeedback: "主体太小")
expect(preference.subjectFraction > 0.5, "Too-small feedback teaches a larger target occupancy")
expect(preference.filterSamples == 0, "Framing complaints must not count as filter approval")
for _ in 0..<3 { preference.learn(context: context, filter: "胶片", strength: 0.6, framingFeedback: "喜欢效果") }
input.preference = preference
expect(DirectorEngine.evaluate(input).filter == "胶片", "Repeated explicit approval teaches a context-specific filter")
let suite = "DirectorTests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let store = DirectorPreferenceStore(defaults: defaults)
store.learn(context: context, filter: "自然", strength: 0.4, framingFeedback: "喜欢效果")
expect(DirectorPreferenceStore(defaults: defaults).feedbackCount == 1, "Feedback survives recreating the preference store")
expect(store.preference(for: DirectorLearningContext(scene: "风景", kind: "object", group: false, subjectFraction: 0.3, automaticFraming: true)) == nil, "Portrait preferences do not leak into a different scene")
store.undoLastFeedback()
expect(store.feedbackCount == 0, "Undo restores preferences before last feedback")
input = fixture()
input.framing = "半身"
expect(DirectorEngine.evaluate(input).evidence.contains { $0.domain == "候选构图" }, "Framing candidates are explained")
input.composition = "三分"
expect(DirectorEngine.evaluate(input).evidence.contains { $0.domain == "候选构图" && $0.observation.contains("2个方案") }, "Explicit thirds compares two anchors")
store.reset()
expect(store.feedbackCount == 0, "Reset removes learned preferences")
defaults.removePersistentDomain(forName: suite)
print("Director tests passed: \(checks)")
