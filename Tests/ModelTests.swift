import Foundation

@main
struct ModelChecks {
    static func main() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let welcome = Notebook.welcome()
        try NotebookValidation.validate(welcome)
        let roundTrip = try decoder.decode(Notebook.self, from: encoder.encode(welcome))
        precondition(welcome == roundTrip, "Notebook round trip must preserve every object and ink byte")
        var settings = StudioSettings(); settings.bridgeToken = "test-secret-not-real"
        let settingsJSON = String(data: try encoder.encode(settings), encoding: .utf8)!
        precondition(!settingsJSON.contains("test-secret-not-real") && !settingsJSON.contains("bridgeToken"), "Pairing token must not enter JSON")
        let missingFields = Data(#"{"kind":"shape","shape":"triangle"}"#.utf8)
        let defaulted = try decoder.decode(CanvasObject.self, from: missingFields)
        try NotebookValidation.validate(defaulted)
        var broken = defaulted; broken.width = -1
        precondition(rejected { try NotebookValidation.validate(broken) }, "Negative dimensions must fail")
        broken = defaulted; broken.properties["x"] = .infinity
        precondition(rejected { try NotebookValidation.validate(broken) }, "Non-finite properties must fail")
        var duplicate = welcome; duplicate.objects.append(welcome.objects[0])
        precondition(rejected { try NotebookValidation.validate(duplicate) }, "Duplicate IDs must fail")
        var future = welcome; future.schemaVersion = 2
        precondition(rejected { try NotebookValidation.validate(future) }, "Unknown versions must fail without overwriting documents")
        let triangle = welcome.objects.first { $0.shape == "triangle" }!
        let command = LocalAssistant.respond(prompt: "Make the triangle green with a starry pattern", objects: welcome.objects)
        precondition(command.operations.count == 1 && command.operations[0].type == "update")
        precondition(command.operations[0].object?.id == triangle.id)
        precondition(command.operations[0].object?.color == "#16A34A" && command.operations[0].object?.pattern == "stars")
        let angles = LocalAssistant.respond(prompt: "Set the triangle angles to 49 and 52", objects: welcome.objects)
        precondition(angles.operations[0].object?.properties["angleC"] == 79)
        let invalidAngles = LocalAssistant.respond(prompt: "Set triangle angles to 120 and 100", objects: welcome.objects)
        precondition(invalidAngles.operations.isEmpty)
        let unknown = LocalAssistant.respond(prompt: "Research an open problem", objects: welcome.objects)
        precondition(unknown.operations.isEmpty && unknown.message.contains("Offline"))
        for prompt in ["Make a coin", "Make a pendulum animation", "Plot a graph", "Make a triangle", "Make a circle"] {
            let result = LocalAssistant.respond(prompt: prompt, objects: welcome.objects)
            for operation in result.operations { if let object = operation.object { try NotebookValidation.validate(object) } }
        }
        print("12 model checks passed: round trip, secret exclusion, defaults, validation, offline mutations and examples")
    }
    static func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
}
