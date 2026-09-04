import AppKit

/// A source plane for Apply Image / Calculations: the whole colour image,
/// one of its planes, or one of the document's alpha channels.
enum PlaneChoice: Equatable {
    /// The colour image. Against an RGB target it applies plane for plane;
    /// against a single plane or a channel it resolves to the source's
    /// Rec. 709 LUMA — the gray Photoshop feeds a single channel with.
    case rgb
    case plane(RasterPlane)
    case channel(Int)
}

/// Image > Apply Image…: one source blended onto the active layer's pixels,
/// one of its colour planes, or an alpha channel.
struct ApplyImageParameters: Equatable {
    /// nil = Merged (the flattened composite).
    var source: Int?
    var sourcePlane: PlaneChoice = .rgb
    var invert = false
    var blend: RzBlendMode = RZ_BLEND_NORMAL
    /// 0…1.
    var opacity: Double = 1
    /// `.layer` | `.plane(p)` | `.channel(i)`; `.mask` is refused.
    var target: PaintTarget = .layer
    /// The layer `.layer` and `.plane` write into.
    var targetLayer = 0
}

/// Image > Calculations…: two sources blended into a new plane, which
/// becomes a channel or the selection.
struct CalculationsParameters: Equatable {
    struct Source: Equatable {
        /// nil = Merged.
        var layer: Int?
        var plane: PlaneChoice = .rgb
        var invert = false
    }

    /// The BLEND layer (Photoshop's Source 1).
    var source1 = Source()
    /// The BASE (Photoshop's Source 2) — the plane the blend is applied to.
    var source2 = Source()
    var blend: RzBlendMode = RZ_BLEND_NORMAL
    var opacity: Double = 1
    /// Name for a `.newChannel` result.
    var name = "Alpha 1"
}

/// The plane reads of ONE Apply Image / Calculations invocation, memoized.
///
/// Every operand in this file is a plane of the same few images: the
/// flattened composite ("Merged"), one layer's canvas-sized pixels, or a
/// channel. Read one at a time through `RasterDocument.compositePlane` /
/// `layerPlane`, an RGB Apply Image from Merged runs `flattened()` THREE
/// times — a full re-projection each, 16 bytes per canvas pixel — and
/// rebuilds the target layer's canvas image three more, once per component,
/// on every preview tick. One reader per invocation collapses that to one
/// flatten and one image per layer.
///
/// The bytes are identical either way: the core's `composite_plane` is
/// `image_plane(flattened())` and its `layer_plane` is
/// `image_plane(layer_canvas_image())`, which is exactly the pair of steps
/// this reader takes apart so the expensive half can be shared.
final class PlaneReader {
    private let doc: RasterDocument
    private var composite: RasterImage?
    private var didFlatten = false
    private var layerImages: [Int: RasterImage] = [:]

    init(_ doc: RasterDocument) {
        self.doc = doc
    }

    /// One plane of Merged (a nil layer) or of one layer, canvas-sized.
    func plane(layer: Int?, _ plane: RasterPlane) -> [UInt8]? {
        // A layer's MASK is not one of its pixel bytes, so it keeps the
        // document reader. Nothing in the two sheets offers it; the case is
        // here so a future caller gets the right answer rather than none.
        guard plane != .mask else {
            guard let layer = layer else { return nil }
            return doc.layerPlane(layer, plane.rz)
        }
        return image(layer: layer)?.plane(plane.rz)
    }

    /// A channel is already one canvas-sized plane: nothing to cache, and no
    /// image behind it to share.
    func channel(_ index: Int) -> [UInt8]? {
        doc.channelPlane(index)
    }

    private func image(layer: Int?) -> RasterImage? {
        guard let layer = layer else {
            if !didFlatten {
                didFlatten = true
                composite = doc.flattened()
            }
            return composite
        }
        if let cached = layerImages[layer] { return cached }
        guard let image = doc.layerCanvasImage(layer) else { return nil }
        layerImages[layer] = image
        return image
    }
}

/// Apply Image and Calculations, computed once for both the UI sheets
/// (EditorViewController+ChannelMath) and their MCP mirrors
/// (AgentServer+Channels), so the two can never drift.
///
/// Every function is pure over `RasterDocument` handles: no undo, no dirty
/// flag, no alerts — the callers wrap the result in their own edit entry
/// point (`applyRasterizingEdit`/`applyEdit` for the UI,
/// `performPixelEdit`/`performGroupedEdit` for the agent). The blend itself
/// is never re-derived here: it is one call into `RasterPlaneMath.blend`,
/// which is the core's blend table.
enum ChannelMath {
    /// The document with Apply Image's result written to its target, or nil
    /// when a source is unavailable or NOTHING changed.
    ///
    /// An RGB target blends its three planes AS ONE COLOUR
    /// (`RasterPlaneMath.blendRGB`), which is the only formulation in which
    /// the four HSL modes mean anything: three independent gray blends would
    /// hand each of them a zero-saturation triple, making Hue, Saturation and
    /// Color the identity and Luminosity a plain Normal.
    ///
    /// It then writes the three results with FALLTHROUGH, not `?`-chaining:
    /// `withLayerPlane` answers nil for a write that changes no byte (the
    /// core's purity rule), and Multiply against a source that is already 0
    /// in one plane — or any single-hue image — makes exactly that happen,
    /// which must not refuse the whole operation.
    static func applyImage(
        _ doc: RasterDocument, _ p: ApplyImageParameters
    ) -> RasterDocument? {
        // ONE reader for the whole invocation: an RGB target reads six planes
        // (three of the source, three of the backdrop) and they come off two
        // images, not six.
        let reader = PlaneReader(doc)
        switch p.target {
        case .layer:
            guard let blended = blendedTriple(reader, doc, p) else { return nil }
            var out = doc
            var changed = false
            for (component, plane) in zip([RasterPlane.red, .green, .blue], blended) {
                guard let next = out.withLayerPlane(p.targetLayer, component.rz, plane) else {
                    continue
                }
                out = next
                changed = true
            }
            return changed ? out : nil
        case .plane(let plane):
            guard let blended = blended(reader, doc, p, targetPlane: plane, component: nil) else {
                return nil
            }
            return doc.withLayerPlane(p.targetLayer, plane.rz, blended)
        case .channel(let index):
            guard let blended = blended(reader, doc, p, targetPlane: nil, component: nil) else {
                return nil
            }
            return doc.settingChannelData(index, blended)
        case .mask:
            // Apply Image targets the composite, a colour plane or an alpha
            // channel — the sheet disables Apply for a mask target rather
            // than inventing a meaning for it.
            return nil
        }
    }

    /// Calculations' resulting plane (canvas-sized), or nil when a source
    /// is unavailable. The caller decides whether it becomes a channel or
    /// the selection. Source 2 is the BASE and Source 1 the blend layer —
    /// Photoshop's convention, and the argument order `RasterPlaneMath`
    /// documents.
    static func calculated(_ doc: RasterDocument, _ p: CalculationsParameters) -> [UInt8]? {
        // ONE reader again: two Merged sources are one flatten between them,
        // not one apiece per preview tick.
        let reader = PlaneReader(doc)
        guard
            var base = sourcePlane(
                reader, layer: p.source2.layer, plane: p.source2.plane,
                invert: p.source2.invert),
            let source = sourcePlane(
                reader, layer: p.source1.layer, plane: p.source1.plane,
                invert: p.source1.invert)
        else { return nil }
        guard
            RasterPlaneMath.blend(
                &base, with: source, width: doc.width, height: doc.height,
                mode: p.blend, opacity: p.opacity,
                // The inversions were already folded into the operands by
                // sourcePlane, which is the same "invert first" rule the
                // core's flags implement — applying them twice would undo
                // them.
                invertBase: false, invertSource: false)
        else { return nil }
        return base
    }

    /// One source's plane, canvas-sized: Merged (nil layer) or one layer,
    /// the chosen plane or channel, inverted if asked. Shared by both entry
    /// points. `matching` names the target plane an `.rgb` source should be
    /// read component for component (Apply Image onto RGB); nil means the
    /// `.rgb` source collapses to LUMA.
    static func sourcePlane(
        _ reader: PlaneReader, layer: Int?, plane: PlaneChoice, invert: Bool,
        matching component: RasterPlane? = nil
    ) -> [UInt8]? {
        let raw: [UInt8]?
        switch plane {
        case .rgb:
            raw = reader.plane(layer: layer, component ?? .luma)
        case .plane(let p):
            raw = reader.plane(layer: layer, p)
        case .channel(let index):
            // A channel is document state, canvas-sized already: `layer`
            // says nothing about it and is deliberately ignored.
            raw = reader.channel(index)
        }
        guard let bytes = raw else { return nil }
        return invert ? PlaneAlgebra.inverted(bytes) : bytes
    }

    /// The plane a target currently holds — Apply Image's backdrop.
    static func targetPlane(
        _ reader: PlaneReader, _ target: PaintTarget, layer: Int, component: RasterPlane?
    ) -> [UInt8]? {
        switch target {
        case .layer:
            guard let component = component else { return nil }
            return reader.plane(layer: layer, component)
        case .plane(let plane):
            return reader.plane(layer: layer, plane)
        case .channel(let index):
            return reader.channel(index)
        case .mask:
            return nil
        }
    }

    /// `blend(target, source)` for the layer's three planes at once, as one
    /// colour — the RGB target's whole arithmetic. Returns red, green and
    /// blue in that order, or nil when a plane is unreadable or the core
    /// refuses the call.
    private static func blendedTriple(
        _ reader: PlaneReader, _ doc: RasterDocument, _ p: ApplyImageParameters
    ) -> [[UInt8]]? {
        let components: [RasterPlane] = [.red, .green, .blue]
        var base: [[UInt8]] = []
        var source: [[UInt8]] = []
        for component in components {
            guard
                let b = targetPlane(reader, p.target, layer: p.targetLayer, component: component),
                let s = sourcePlane(
                    reader, layer: p.source, plane: p.sourcePlane, invert: p.invert,
                    matching: component)
            else { return nil }
            base.append(b)
            source.append(s)
        }
        var red = base[0]
        var green = base[1]
        var blue = base[2]
        guard
            RasterPlaneMath.blendRGB(
                red: &red, green: &green, blue: &blue,
                withRed: source[0], green: source[1], blue: source[2],
                width: doc.width, height: doc.height, mode: p.blend, opacity: p.opacity,
                // The inversion was already folded into the source by
                // sourcePlane — the same "invert first" rule the core's flags
                // implement, and applying it twice would undo it.
                invertBase: false, invertSource: false)
        else { return nil }
        return [red, green, blue]
    }

    /// `blend(target, source)` for one plane of the target.
    private static func blended(
        _ reader: PlaneReader, _ doc: RasterDocument, _ p: ApplyImageParameters,
        targetPlane plane: RasterPlane?, component: RasterPlane?
    ) -> [UInt8]? {
        guard
            var base = targetPlane(reader, p.target, layer: p.targetLayer, component: plane),
            let source = sourcePlane(
                reader, layer: p.source, plane: p.sourcePlane, invert: p.invert,
                matching: component)
        else { return nil }
        guard
            RasterPlaneMath.blend(
                &base, with: source, width: doc.width, height: doc.height,
                mode: p.blend, opacity: p.opacity, invertBase: false, invertSource: false)
        else { return nil }
        return base
    }
}
