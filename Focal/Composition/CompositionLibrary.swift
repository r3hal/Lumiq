import Foundation

/// Shared by the planner and the photography guide. These are alternatives,
/// not universal rules, and some require evidence the local model cannot infer.
enum CompositionTechnique: String, CaseIterable, Identifiable {
    case thirds = "Rule of thirds", centered = "Centered", symmetry = "Symmetry"
    case goldenRatio = "Golden ratio", negativeSpace = "Negative space"
    case fillFrame = "Fill the frame", leadingLines = "Leading lines", diagonals = "Diagonals"
    case framing = "Frame within a frame", balance = "Visual balance", triangles = "Triangles"
    case odds = "Rule of odds", repetition = "Patterns and repetition", layers = "Layered composition"
    case simplicity = "Simplify the background", contrast = "Color and light contrast"
    case horizon = "Horizon placement", reflection = "Reflections"
    case leadRoom = "Looking and movement room", curves = "Curves and golden spiral"
    case perspective = "Perspective and viewpoint", juxtaposition = "Juxtaposition"
    var id: Self { self }
    var automatic: Bool {
        ![Self.leadRoom, .curves, .perspective, .juxtaposition, .reflection].contains(self)
    }
    var advice: String {
        switch self {
        case .thirds: return "Place a clear subject near a thirds intersection; keep its edges inside the frame."
        case .centered: return "Center a strong isolated subject when its shape deserves attention."
        case .symmetry: return "Align the center of a genuinely mirrored scene. A plain wall is not symmetry evidence."
        case .goldenRatio: return "Try a gentler off-center placement near 38% or 62% of the frame."
        case .negativeSpace: return "Give a small subject room beside a calm, uncluttered area."
        case .fillFrame: return "Tighten around the subject while preserving its boundaries and image detail."
        case .leadingLines: return "Keep visible lines that lead toward the subject, rather than out of the frame."
        case .diagonals: return "Preserve strong diagonal lines for energy; keep the camera itself level."
        case .framing: return "Keep an enclosing arch, window or foreground shape around the subject."
        case .balance: return "Balance the main subject with a smaller visible element on the other side."
        case .triangles: return "Keep three separated subjects that form a clear triangle together."
        case .odds: return "Preserve an observed group of three or five rather than cutting one out."
        case .repetition: return "Keep repeated shapes together; an interruption can become the subject."
        case .layers: return "Keep separated foreground and background elements for context. Their depth is not measured."
        case .simplicity: return "Remove busy edges without cutting into the subject. A different angle may work better than zoom."
        case .contrast: return "Keep the subject distinct from its surroundings through observed color or light contrast."
        case .horizon: return "Give a landscape's sky or foreground more space. A detected horizontal edge is only a candidate horizon."
        case .reflection: return "A centered horizon can suit a reflection. Confirm the reflection yourself."
        case .leadRoom: return "Leave room in the direction the subject looks or moves. Focal does not infer gaze from a box."
        case .curves: return "Use a real curved path or spiral to guide the eye. Golden-ratio placement alone is not a spiral."
        case .perspective: return "Try a lower, higher or side viewpoint; the app cannot see around objects for you."
        case .juxtaposition: return "Compare contrasting subjects with a story in mind. A local classifier cannot know your intended story."
        }
    }
    var evidenceDescription: String {
        switch self {
        case .thirds, .centered, .goldenRatio: return "Subject boundaries and placement"
        case .symmetry: return "Mirrored pixels with visible variation"
        case .negativeSpace: return "Measured calm background space"
        case .fillFrame, .simplicity: return "Subject retention, background edges and zoom budget"
        case .leadingLines, .diagonals: return "Long continuous edges outside the subject"
        case .framing: return "An enclosing rectangle in the actual preview"
        case .balance, .triangles, .odds, .layers: return "Fresh, separate detected subjects"
        case .repetition: return "Periodic image structure with contrast"
        case .contrast: return "Measured subject/background color separation"
        case .horizon: return "Landscape classification and a long horizontal edge"
        default: return "Photography advice · verify visually"
        }
    }
}
