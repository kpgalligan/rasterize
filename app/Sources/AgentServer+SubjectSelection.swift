import AppKit

/// The agent's subject segmentation, mirroring both UI paths: Select >
/// Select Subject (EditorViewController+SubjectSelection), which takes every
/// subject at once, and the Subject tool's press-and-hold
/// (SubjectSession in SubjectSelection.swift), which takes the one under the
/// pointer. The model is SubjectSelection.swift.
extension AgentServer {
    /// Selects the foreground subjects Vision finds in the composite.
    ///
    /// `instance` is this tool's equivalent of clicking a particular subject
    /// on the canvas — a model has no pointer, so it addresses subjects by
    /// number instead, and every result reports the total so "select just
    /// the person on the left" becomes select all → read the count → try
    /// each instance and compare bounds.
    func selectSubject(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else {
            throw ToolError(message: "Document has no image")
        }
        let instance = intArg(a, "instance")
        if let instance = instance, instance < 1 {
            throw ToolError(
                message: "instance is 1-based; omit it to select every subject at once")
        }
        let subjects: SubjectSelection.Subjects
        do {
            subjects = try doc.subjectMask(instance: instance)
        } catch let failure as SubjectSelection.Failure {
            // In-band, like every other handler failure, so the model can
            // read "no subject was found" and change approach rather than
            // seeing a transport error.
            throw ToolError(message: failure.message)
        }
        return try applySelection(
            document, .mask(subjects.mask), mode: selectionMode(a),
            extra: ["instances": subjects.instanceCount])
    }
}
