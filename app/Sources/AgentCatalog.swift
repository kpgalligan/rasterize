import Foundation

// MARK: - Catalog

/// The MCP tool catalog AgentServer registers with the core: every tool's
/// name, description, and JSON-Schema input. The names here must match
/// AgentServer.handlers exactly — start() asserts the parity in debug builds.
extension AgentServer {
    private func tool(
        _ name: String, _ description: String,
        _ properties: [String: Any], required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object", "properties": properties, "required": required,
            ] as [String: Any],
        ]
    }

    private static let docIDProperty: [String: Any] = [
        "type": "integer",
        "description": "Target document id from list_documents; omit for the frontmost document.",
    ]

    func catalogJSON() throws -> String {
        let docID = Self.docIDProperty
        let index: [String: Any] = [
            "type": "integer",
            "description": "Layer index (0 = bottom); omit for the active layer.",
        ]
        let selectionMode: [String: Any] = [
            "type": "string",
            "enum": ["replace", "add", "subtract", "intersect"],
            "description": "How the new shape combines with the current selection "
                + "(default replace). add unions, subtract removes the new shape from "
                + "the current selection, intersect keeps the overlap; an empty result "
                + "clears the selection.",
        ]
        let blendNames = RzBlendMode.allBlendModes.map { $0.1 }
        // The modes a SINGLE 8-bit plane can carry: the four HSL modes are
        // defined over an RGB triple, so `rz_blend_planes` refuses them and
        // calculations — whose result is always one plane — must not offer
        // them as schema-valid values (the sheet's popup filters the same
        // list through ChannelMathControls.fillBlendModes).
        let planeBlendNames = RzBlendMode.allBlendModes
            .filter { !RzBlendMode.degeneratesOnGray($0.0) }
            .map { $0.1 }
        // The tip options every stroke tool shares beyond hardness — the
        // same knobs the options bar's paint tools carry.
        let flowProperty: [String: Any] = [
            "type": "number", "minimum": 1, "maximum": 100,
            "description": "Per-dab deposit in percent (default 100). Below 100 the "
                + "stroke builds up where it overlaps itself instead of landing at full "
                + "strength at once.",
        ]
        let spacingProperty: [String: Any] = [
            "type": "number", "minimum": 1, "maximum": 200,
            "description": "Dab spacing as a percent of the brush diameter (default 25). "
                + "Above 25 the stroke stamps visibly; 150+ reads as a dotted line.",
        ]
        let angleProperty: [String: Any] = [
            "type": "number", "minimum": -180, "maximum": 180,
            "description": "Tip rotation in degrees, counter-clockwise (default 0). "
                + "Visible only when roundness is below 100.",
        ]
        let roundnessProperty: [String: Any] = [
            "type": "number", "minimum": 1, "maximum": 100,
            "description": "Tip roundness in percent (default 100). Below 100 the dab "
                + "squashes into an ellipse — with angle, a calligraphy nib.",
        ]
        let strokeBlendProperty: [String: Any] = [
            "type": "string", "enum": blendNames,
            "description": "Blend mode the stroke's paint composites with (default Normal) "
                + "— the layer blend-mode names. Not valid with a coverage target — a "
                + "mask, a colour plane or a channel.",
        ]
        // The widened paint target: a colour plane or an alpha channel is
        // coverage exactly like a mask. Shared by brush_stroke,
        // eraser_stroke and apply_filter, which differ only in the prose
        // above it, so the vocabulary is written once.
        let targetVocabulary =
            "\"layer\" (default) the layer's own pixels, \"mask\" the layer's mask, "
            + "\"red\"/\"green\"/\"blue\"/\"alpha\" ONE colour plane of that layer's "
            + "pixels, or \"channel:<name>\" one of the document's alpha channels "
            + "(list_channels names them)."
        // The one exception to "every other plane byte-identical", and it
        // destroys data: the plane WRITER clears a pixel's colour bytes when
        // its new alpha is 0 — the core's straight-alpha rule, stated for
        // rz_doc_with_layer_plane in the C header — so inverting alpha twice
        // does not bring the colours back. It rides with the tools that WRITE
        // a whole plane (apply_filter, fill, gradient); the stroke ops
        // deliberately do the opposite ("a stroke is incremental" —
        // painting_layer_plane never clears colour), so they must not carry it.
        let alphaWriteNote =
            " Writing \"alpha\" is the one exception to that: every pixel whose new "
            + "alpha is 0 loses its colour bytes as well, so re-running the edit "
            + "does not bring them back."
        let cloneBlendProperty: [String: Any] = [
            "type": "string", "enum": blendNames,
            "description": "Blend mode the cloned paint composites with (default Normal) "
                + "— the layer blend-mode names.",
        ]
        // The text-layer typography every text tool takes — the options
        // bar's own knobs — and the described layers' shared transform.
        let textWeightProperty: [String: Any] = [
            "type": "integer", "minimum": 0, "maximum": 15,
            "description": "NSFontManager weight 0-15: 3 light, 5 regular (default), 6 "
                + "medium, 8 semibold, 9 bold — the options bar's Weight popup.",
        ]
        let textItalicProperty: [String: Any] = [
            "type": "boolean", "description": "Italic face (default false).",
        ]
        let textUnderlineProperty: [String: Any] = [
            "type": "boolean", "description": "Single underline (default false).",
        ]
        let textStrikethroughProperty: [String: Any] = [
            "type": "boolean", "description": "Single strikethrough (default false).",
        ]
        let textTrackingProperty: [String: Any] = [
            "type": "number", "minimum": -100, "maximum": 100,
            "description": "Extra spacing between glyphs in px (kern), -100 to 100, "
                + "default 0 — the options bar's Tracking field.",
        ]
        let textLeadingProperty: [String: Any] = [
            "type": "number", "minimum": 0, "maximum": 1000,
            "description": "Line height in px, 0 to 1000; 0 (default) = the font's natural "
                + "height — the options bar's Leading field.",
        ]
        let textBaselineProperty: [String: Any] = [
            "type": "number", "minimum": -100, "maximum": 100,
            "description": "Baseline shift in px, -100 to 100, positive raises the text, "
                + "default 0 — the options bar's Baseline field.",
        ]
        let transformProperty: (String) -> [String: Any] = { role in
            [
                "type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
                "description": "The layer's 2×2 linear map [a, b, c, d], row-major — "
                    + "(x, y) maps to (a·x + b·y, c·x + d·y) — \(role); default "
                    + "[1, 0, 0, 1]. Rotation by θ clockwise is [cos θ, -sin θ, sin θ, "
                    + "cos θ]. transform_layer composes onto it; get_document reports it.",
            ]
        }
        let catalog: [[String: Any]] = [
            tool(
                "list_documents",
                "Lists the images open in Rasterize with their ids, sizes, and layer counts.",
                [:]),
            tool(
                "open_document",
                "Opens an image file (PNG, JPEG, PSD, TIFF, BMP, GIF, WebP, RZ) in a new "
                    + "editor window and returns its document id.",
                ["path": ["type": "string", "description": "Absolute or ~ path to the file."]],
                required: ["path"]),
            tool(
                "get_document",
                "Full state of one document: canvas size and every layer's name, size, offset, "
                    + "opacity, blend mode, visibility, layer mask (has_mask, mask_enabled), "
                    + "and clipped flag (see set_layer_clipped). A STYLED layer reports a "
                    + "style object — its whole effect stack and blending options as the "
                    + "canonical JSON set_layer_style takes back — and the document reports "
                    + "global_light (angle, altitude). "
                    + "A re-editable TEXT layer also reports a text object (string, font, size, "
                    + "color, alignment, weight, italic, tracking, leading, baseline_shift, "
                    + "underline, strikethrough, box_width, transform, origin) — those are the "
                    + "layers edit_text_layer can change — a SHAPE layer a shape object (kind, "
                    + "w, h, fill, stroke, stroke_width, radius, transform, origin), and a LIVE "
                    + "PHOTO layer a live_photo object (video, still, time, key_time, duration, "
                    + "showing_still, width, height, transform, origin); a layer without those "
                    + "keys is plain pixels. transform is the layer's 2×2 map [a, b, c, d], "
                    + "row-major — (x, y) maps to (a·x + b·y, c·x + d·y) — and "
                    + "origin the exact canvas position of its source's top-left (the text "
                    + "block's, the shape box's, the still's; fractional after a transform). "
                    + "An ADJUSTMENT layer reports "
                    + "is_adjustment true plus an adjustment object (op, params) — those are "
                    + "the layers edit_adjustment_layer can change. A document that carries "
                    + "ALPHA CHANNELS (saved selections, never part of the picture) also "
                    + "reports a channels array of {index, name, overlay_color, "
                    + "overlay_opacity, color_indicates} — list_channels returns the same "
                    + "list. Layer index 0 is the bottom "
                    + "layer; offsets are measured from the canvas top-left corner, y "
                    + "increasing down.",
                ["document_id": docID]),
            tool(
                "render",
                "Renders the flattened canvas (or one layer) as a PNG image so you can see it. "
                    + "Use this to inspect the picture before and after edits.",
                [
                    "document_id": docID, "layer": index,
                    "max_side": [
                        "type": "integer",
                        "description": "Longest output side in px (64-4096, default 1024).",
                    ],
                    "channel": [
                        "type": "string",
                        "description": "Renders ONE plane as a grayscale PNG instead of the "
                            + "colour image: \"red\", \"green\", \"blue\", \"alpha\", "
                            + "\"luma\", or an alpha channel's name (list_channels shows "
                            + "them). With layer it is that layer's plane, canvas-sized "
                            + "with 0 outside the layer's rect; otherwise the flattened "
                            + "composite's.",
                    ],
                ]),
            tool(
                "sample_color",
                "Reads the color of one pixel of the flattened composite (what you see "
                    + "in a render) — the eyedropper. Returns straight (non-premultiplied) "
                    + "RGBA components (0-255) and the hex string (#RRGGBB, or #RRGGBBAA "
                    + "when not fully opaque). Errors when the point is outside the canvas.",
                [
                    "x": [
                        "type": "integer",
                        "description": "Pixel x in canvas coordinates (0 = left edge).",
                    ],
                    "y": [
                        "type": "integer",
                        "description": "Pixel y in canvas coordinates (0 = top edge).",
                    ],
                    "document_id": docID,
                ], required: ["x", "y"]),
            tool(
                "set_active_layer",
                "Selects the layer that untargeted edits apply to.",
                ["index": ["type": "integer"], "document_id": docID], required: ["index"]),
            tool(
                "new_layer",
                "Adds an empty transparent layer above the active layer and selects it.",
                ["name": ["type": "string"], "document_id": docID]),
            tool(
                "duplicate_layer", "Duplicates a layer.",
                ["index": index, "document_id": docID]),
            tool(
                "delete_layer", "Deletes a layer (the last layer cannot be deleted).",
                ["index": index, "document_id": docID]),
            tool(
                "merge_down", "Merges a layer into the one below it.",
                ["index": index, "document_id": docID]),
            tool(
                "flatten_image", "Flattens all layers into one.",
                ["document_id": docID]),
            tool(
                "reorder_layer", "Moves a layer to a new stack position.",
                [
                    "from": ["type": "integer"], "to": ["type": "integer"],
                    "document_id": docID,
                ], required: ["from", "to"]),
            tool(
                "set_layer_properties",
                "Changes any of a layer's name, opacity (0-1), blend mode, visibility, or "
                    + "pixel offset in one undoable step.",
                [
                    "index": index,
                    "name": ["type": "string"],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "blend_mode": ["type": "string", "enum": blendNames],
                    "visible": ["type": "boolean"],
                    "offset_x": ["type": "integer"],
                    "offset_y": ["type": "integer"],
                    "document_id": docID,
                ]),
            tool(
                "transform_layer",
                "Rotates, scales and/or moves ONE layer's pixels in a single resample — the "
                    + "same pipeline as the app's Free Transform (⌘T). The rotation and the "
                    + "scales act around a pivot (by default the centre of the layer's CURRENT "
                    + "bounds — for a re-editable text, shape or Live Photo layer the exact "
                    + "centre of its description's box, which a turn leaves fixed, so rotate "
                    + "then rotate-back returns it exactly), then the translation is added; "
                    + "the layer is resampled once "
                    + "into the outward-rounded bounding box of its transformed corners, so "
                    + "its offset AND size both change, and it may end up extending past the "
                    + "canvas. The canvas and every other layer are untouched, and a layer "
                    + "mask rides along, resampled identically. Pass at least one of rotate, "
                    + "scale, scale_x, scale_y, translate_x, translate_y; the result reports "
                    + "the layer's new bounds so you can verify placement. For whole-document "
                    + "geometry use rotate / flip / image_size instead. On a re-editable TEXT, "
                    + "SHAPE or LIVE PHOTO layer nothing rasterizes: the matrix composes into "
                    + "the layer's description and the layer re-renders through it (crisp "
                    + "vector edges; the result says rasterized: false and reports the new "
                    + "transform and origin). Only a layer whose source cannot be rendered "
                    + "right now (a text family not installed here, a Live Photo whose files "
                    + "are gone) is resampled as pixels and drops its description, reported "
                    + "as before with the reason (undo restores it).",
                [
                    "layer": index,
                    "rotate": [
                        "type": "number",
                        "description": "Rotation in degrees around the pivot. POSITIVE IS "
                            + "CLOCKWISE on screen (canvas y grows downward), matching the "
                            + "app's Angle field. Default 0.",
                    ],
                    "scale": [
                        "type": "number",
                        "description": "Uniform scale multiplier for both axes: 1 = unchanged "
                            + "(default), 0.5 = half size, 2 = double, negative mirrors. "
                            + "scale_x / scale_y override it per axis. Magnitudes are clamped "
                            + "to 0.001-100 and 0 is refused.",
                    ],
                    "scale_x": [
                        "type": "number",
                        "description": "Horizontal scale multiplier, overriding scale "
                            + "(1 = unchanged, negative mirrors left-right).",
                    ],
                    "scale_y": [
                        "type": "number",
                        "description": "Vertical scale multiplier, overriding scale "
                            + "(1 = unchanged, negative mirrors top-bottom).",
                    ],
                    "translate_x": [
                        "type": "number",
                        "description": "Move right by this many canvas px (negative = left), "
                            + "applied after the rotation and scale.",
                    ],
                    "translate_y": [
                        "type": "number",
                        "description": "Move down by this many canvas px (negative = up), "
                            + "applied after the rotation and scale.",
                    ],
                    "around": [
                        "type": "string",
                        "enum": ["center", "top_left"],
                        "description": "The pivot the rotation and scale turn/grow around: "
                            + "\"center\" (default) or \"top_left\" of the layer's current "
                            + "bounds; center is a described layer's exact centre, shared "
                            + "with the app's ⌘T session. pivot_x / pivot_y override it.",
                    ],
                    "pivot_x": [
                        "type": "number",
                        "description": "Explicit pivot x in canvas px; overrides around on "
                            + "this axis.",
                    ],
                    "pivot_y": [
                        "type": "number",
                        "description": "Explicit pivot y in canvas px; overrides around on "
                            + "this axis.",
                    ],
                    "sampler": [
                        "type": "string",
                        "enum": ["nearest", "bilinear", "bicubic", "lanczos"],
                        "description": "Resampling filter, default bicubic (Catmull-Rom). "
                            + "nearest keeps hard pixel edges (pixel art), lanczos is "
                            + "sharpest for big reductions. Whole-pixel moves and mirrors "
                            + "(scale -1) copy pixels losslessly whatever this says; every "
                            + "rotation is resampled, so for a lossless quarter turn of the "
                            + "WHOLE image use the rotate tool instead.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "distort_layer",
                "Perspective/distort of ONE layer: maps the layer's rect corner-for-corner "
                    + "onto four explicit canvas points — the same projective pipeline as "
                    + "⌘-dragging a Free Transform corner in the app. Pass the destinations "
                    + "of the rect's top-left, top-right, bottom-right and bottom-left "
                    + "corners; they must form a convex quad (a concave or self-crossing "
                    + "arrangement folds the mapping and is refused). A parallelogram is "
                    + "committed as the exact affine it is — whole-pixel moves stay "
                    + "lossless, and on a re-editable text, shape or Live Photo layer it "
                    + "composes into the description like transform_layer (rasterized: "
                    + "false). The layer is otherwise resampled once into the corners' "
                    + "outward-rounded bounding box, so offset AND size change; a layer "
                    + "mask rides along identically, and other layers and the canvas are "
                    + "untouched. A true perspective quad rewrites pixels, so a described "
                    + "layer drops its description (rasterized_text / _shape / _live_photo: "
                    + "true; undo restores it). The result reports the layer's new bounds "
                    + "for verification.",
                [
                    "layer": index,
                    "corners": [
                        "type": "array",
                        "description": "Four [x, y] canvas points, the destinations of the "
                            + "layer rect's TL, TR, BR and BL corners in that order, e.g. "
                            + "[[0, 0], [80, 10], [75, 60], [5, 50]]. Pixels are y-down: "
                            + "the canvas origin is its top-left.",
                        "items": [
                            "type": "array",
                            "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 4, "maxItems": 4,
                    ],
                    "sampler": [
                        "type": "string",
                        "enum": ["nearest", "bilinear", "bicubic", "lanczos"],
                        "description": "Resampling filter, default bicubic (Catmull-Rom). "
                            + "Perspective compresses detail toward the quad's narrow side, "
                            + "where bicubic or lanczos hold up best.",
                    ],
                    "document_id": docID,
                ], required: ["corners"]),
            tool(
                "add_layer_mask",
                "Gives a layer a mask: a grayscale coverage channel that gates the layer's "
                    + "alpha without touching its pixels (white shows, black hides, grays are "
                    + "partial), so hiding is non-destructive and reversible. The mask is the "
                    + "layer's size and moves with it. Replaces any existing mask and enables "
                    + "it. Paint it afterwards with brush_stroke / eraser_stroke and "
                    + "target: \"mask\".",
                [
                    "layer": index,
                    "kind": [
                        "type": "string",
                        "enum": ["reveal_all", "hide_all", "from_selection"],
                        "description": "reveal_all (default) starts fully white — nothing "
                            + "hidden yet; hide_all starts black — the layer disappears until "
                            + "you paint it back; from_selection builds the mask from the "
                            + "CURRENT selection (selected shows, the rest hides), so it "
                            + "requires an active selection from a select_* tool.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "remove_layer_mask",
                "Removes a layer's mask. With apply: true the coverage is first BAKED into "
                    + "the layer's alpha — permanent, pixels lost, and it bakes regardless of "
                    + "whether the mask was enabled — so what the mask hid becomes really "
                    + "erased. With apply: false (the default) the mask is simply discarded "
                    + "and the layer is revealed in full again, pixels untouched.",
                [
                    "layer": index,
                    "apply": [
                        "type": "boolean",
                        "description": "Bake the mask into the layer's alpha before dropping "
                            + "it (default false = discard it).",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "set_layer_mask_enabled",
                "Turns a layer's mask on or off. A disabled mask is kept (and saved) but "
                    + "ignored while compositing, so the layer shows in full — useful to "
                    + "compare with and without. Errors when the layer has no mask.",
                [
                    "layer": index,
                    "enabled": ["type": "boolean"],
                    "document_id": docID,
                ], required: ["enabled"]),
            tool(
                "set_layer_clipped",
                "Clips a layer to the one below it (a Photoshop clipping mask) or releases "
                    + "it. A clipped layer only shows where the first UNCLIPPED layer "
                    + "beneath it has content — that base layer's alpha footprint gates the "
                    + "whole group, and the group blends as one unit with the base's blend "
                    + "mode and opacity. Grouping is positional: consecutive clipped layers "
                    + "above a base all clip to it, and reordering re-derives the groups "
                    + "with no extra bookkeeping. Hiding the base hides its group. "
                    + "Non-destructive and reversible: pixels are untouched either way.",
                [
                    "layer": index,
                    "clipped": [
                        "type": "boolean",
                        "description": "true clips the layer to the one below; false "
                            + "releases it.",
                    ],
                    "document_id": docID,
                ], required: ["clipped"]),
            tool(
                "set_layer_style",
                "Replaces a layer's WHOLE layer style — Photoshop's effect stack plus "
                    + "blending options — in one undoable step; the same object get_document "
                    + "reports as style. Shape: {\"fill_opacity\": 0..1 (default 1; scales "
                    + "the pixels, never the effects), \"blend_if\": null or {channel: "
                    + "gray|red|green|blue, this_layer: [lo0, lo1, hi0, hi1], underlying: "
                    + "[lo0, lo1, hi0, hi1]} with 0..255 ramps in order (weight fades in "
                    + "over lo0..lo1 and out over hi0..hi1; [0, 0, 255, 255] is full weight), "
                    + "\"effects\": [ ... ]}. Effects, at most one per type, each with "
                    + "\"type\", \"enabled\" (default true), its own \"blend\" and "
                    + "\"opacity\" 0..1 — defaults in parentheses: drop_shadow (multiply, "
                    + "color #000000, opacity 0.75, angle 120, use_global_light true, distance "
                    + "5 px, spread 0..1 (0), size 0..250 px (5), layer_knocks_out true); "
                    + "inner_shadow (multiply, #000000, 0.75, angle 120, use_global_light "
                    + "true, distance 5, choke 0, size 5); outer_glow (screen, #ffffbe, 0.75, "
                    + "spread 0, size 5); inner_glow (screen, #ffffbe, 0.75, choke 0, size 5, "
                    + "source edge|center); stroke (normal, opacity 1, size 3, position "
                    + "outside|inside|center, fill_type color|gradient, color #000000, "
                    + "gradient); color_overlay (normal, #ff0000, 1); gradient_overlay "
                    + "(normal, 1, gradient); bevel_emboss (style outer_bevel|inner_bevel|"
                    + "emboss|pillow_emboss, depth 1 = 100 %, direction up|down, size 5, "
                    + "soften 0..16 (0), angle 120, use_global_light true, altitude 0..90 "
                    + "(30), highlight_blend screen, highlight_color #ffffff, "
                    + "highlight_opacity 0.75, shadow_blend multiply, shadow_color #000000, "
                    + "shadow_opacity 0.75); satin (multiply, #000000, 0.5, angle 19, "
                    + "distance 11, size 14, invert true). A gradient is {stops: [{position "
                    + "0..1, color, opacity}, ...] (2..32), style linear|radial|angle|"
                    + "reflected|diamond, angle 90, scale 0.1..1.5, reverse false, "
                    + "align_with_layer true}. Blend names are the snake_case forms of the "
                    + "layer blend modes (normal, multiply, screen, linear_dodge, ...); "
                    + "colors are \"#rrggbb\"; angles are degrees, 0 = light from the right, "
                    + "90 = from the top (120 casts down-right); sizes are canvas px; "
                    + "spread/choke are fractions of size. Effects with use_global_light "
                    + "read the document's global light (set_global_light). Numbers are "
                    + "stored to 4 decimals; unknown keys are ignored, ranges clamped, and "
                    + "an unknown type or enum value is an error whose message names the "
                    + "key. null (or an omitted style) clears; so does a style with no "
                    + "enabled effect, fill_opacity 1 and no blend_if. Idempotent: an "
                    + "unchanged style reports unchanged: true. The whole style replaces "
                    + "the previous one, so read it back from get_document first to change "
                    + "one knob. Effects render from the layer's shape (alpha × mask) at "
                    + "composite time — render shows them, layer renders and thumbnails do "
                    + "not — and follow moves, mask edits and text re-renders; "
                    + "transform_layer, distort_layer and image_size scale the px sizes "
                    + "(Scale Effects); merge_down and flatten_image bake them in. "
                    + "Interior effects use their own blend mode; the layer's blend mode "
                    + "applies to its pixels. Refused on an adjustment layer.",
                [
                    "layer": index,
                    "style": [
                        "type": ["object", "null"],
                        "description": "The whole style object described above, or null "
                            + "to clear.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "set_global_light",
                "Sets the document's global light — the direction every effect with "
                    + "use_global_light on (drop shadow, inner shadow, bevel & emboss by "
                    + "default) reads instead of its own angle, so one edit re-lights every "
                    + "styled layer. Either argument may be omitted; the light defaults to "
                    + "angle 120 (down-right shadows), altitude 30. Altitude is clamped to "
                    + "0..90, the angle normalized to -180..180, both stored to 4 decimals "
                    + "(so the value get_document reports echoes back as unchanged); an "
                    + "unchanged light reports unchanged: true. get_document reports "
                    + "global_light.",
                [
                    "angle": [
                        "type": "number",
                        "description": "Degrees: 0 = light from the right, 90 = from the top.",
                    ],
                    "altitude": [
                        "type": "number", "minimum": 0, "maximum": 90,
                        "description": "Degrees above the canvas plane (bevel shading only).",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "add_adjustment_layer",
                "Adds a NON-DESTRUCTIVE adjustment layer above the active layer and selects "
                    + "it: while compositing it recolors everything below it, its own pixels "
                    + "are ignored, and its parameters stay editable with "
                    + "edit_adjustment_layer (get_document reports them) — same math as "
                    + "apply_filter's matching filters, but reversible. The layer always gets "
                    + "a mask gating where the adjustment applies: built from the current "
                    + "selection when one exists (which stays active), else reveal-all; "
                    + "brush/eraser strokes on the layer paint that mask. Ops and their "
                    + "params: bcs (brightness, contrast, saturation, each -1..1, default 0); "
                    + "curves (rgb, r, g, b: each an optional array of 2-16 [in, out] control "
                    + "points, values 0-255, monotone-interpolated; a missing channel is "
                    + "identity; per-channel curves apply before rgb); levels (black default "
                    + "0, white default 1, 0 <= black < white <= 1; gamma 0.1-10, default 1); "
                    + "hue_rotate (degrees, default 0); threshold (level 0-1, default 0.5); "
                    + "posterize (levels, integer 2-64, REQUIRED); invert, grayscale, sepia "
                    + "(none).",
                [
                    "op": [
                        "type": "string",
                        "enum": AdjustmentLayerOp.allCases.map { $0.rawValue },
                        "description": "The adjustment operation.",
                    ],
                    "params": [
                        "type": "object",
                        "description": "Parameters for op (see the tool description); omit "
                            + "for that op's defaults. posterize has no default: its levels "
                            + "is required.",
                    ],
                    "name": [
                        "type": "string",
                        "description": "Layer name (default: the op's display name).",
                    ],
                    "document_id": docID,
                ], required: ["op"]),
            tool(
                "edit_adjustment_layer",
                "Changes an existing adjustment layer non-destructively by replacing its "
                    + "stored description — one undo step; pixels, mask, opacity, blend mode "
                    + "and stacking are untouched. params REPLACES the whole params object "
                    + "(pass every key you want kept — nothing is merged); op without params "
                    + "switches the layer to that op's defaults. Ops and params exactly as in "
                    + "add_adjustment_layer. Errors when the target layer is not an "
                    + "adjustment layer.",
                [
                    "layer": index,
                    "op": [
                        "type": "string",
                        "enum": AdjustmentLayerOp.allCases.map { $0.rawValue },
                        "description": "New operation; omit to keep the layer's current op.",
                    ],
                    "params": [
                        "type": "object",
                        "description": "Replacement params object for the op (see "
                            + "add_adjustment_layer).",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "apply_filter",
                "Applies a filter or adjustment DESTRUCTIVELY to one layer's pixels (prefer "
                    + "add_adjustment_layer for a reversible color adjustment; this tool "
                    + "errors on an adjustment layer). Filters and their "
                    + "parameters: grayscale, invert, sepia, edge_detect, emboss (none); "
                    + "blur (sigma, default 4); sharpen (amount, default 1); adjust "
                    + "(brightness, contrast, saturation, each -1..1, default 0); levels "
                    + "(black 0-1, white 0-1, gamma 0.1-10); hue_rotate (degrees); threshold "
                    + "(level 0-1); posterize (levels 2-64); pixelate (block 1-1024); "
                    + "add_noise (amount 0-1, seed).",
                [
                    "filter": [
                        "type": "string",
                        "enum": [
                            "grayscale", "invert", "sepia", "edge_detect", "emboss", "blur",
                            "sharpen", "adjust", "levels", "hue_rotate", "threshold",
                            "posterize", "pixelate", "add_noise",
                        ],
                    ],
                    "layer": index,
                    "sigma": ["type": "number"], "amount": ["type": "number"],
                    "brightness": ["type": "number"], "contrast": ["type": "number"],
                    "saturation": ["type": "number"], "black": ["type": "number"],
                    "white": ["type": "number"], "gamma": ["type": "number"],
                    "degrees": ["type": "number"], "level": ["type": "number"],
                    "levels": ["type": "integer"], "block": ["type": "integer"],
                    "seed": ["type": "integer"],
                    "target": [
                        "type": "string",
                        "description": "What the filter runs on: \"layer\" (default) the "
                            + "layer's own pixels, \"red\"/\"green\"/\"blue\"/\"alpha\" ONE "
                            + "colour plane of them, or \"channel:<name>\" one of the "
                            + "document's alpha channels (list_channels names them). A "
                            + "plane is 8-bit gray: the filter runs on it and the result's "
                            + "gray goes back in, leaving every other plane byte-identical."
                            + alphaWriteNote,
                    ],
                    "document_id": docID,
                ], required: ["filter"]),
            tool(
                "brush_stroke",
                "Paints a brush stroke onto a layer's pixels: a smooth polyline through "
                    + "points (canvas coordinates) with round caps and joins. One point "
                    + "paints a dot. Draw shapes with several strokes; use render to check "
                    + "the result. With target: \"mask\" the same stroke paints the layer's "
                    + "mask instead, revealing what it covers.",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] along the stroke, in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 1, "maxItems": 10_000,
                    ],
                    "size": [
                        "type": "number",
                        "description": "Stroke width in px (1-512, default 16).",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000). "
                            + "Ignored when target is \"mask\".",
                    ],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "hardness": [
                        "type": "number", "minimum": 0, "maximum": 100,
                        "description": "Edge hardness in percent (default 100 = crisp). "
                            + "Below 100 the stroke stamps soft round dabs whose alpha "
                            + "fades from hardness% of the radius out to the rim — an "
                            + "airbrushed edge.",
                    ],
                    "flow": flowProperty,
                    "spacing": spacingProperty,
                    "angle": angleProperty,
                    "roundness": roundnessProperty,
                    "blend_mode": strokeBlendProperty,
                    "layer": index,
                    "target": [
                        "type": "string",
                        "description": "What the stroke paints: " + targetVocabulary
                            + " On a mask the stroke REVEALS what it covers. Coverage is "
                            + "not color, so every target but \"layer\" forces the stroke "
                            + "to WHITE whatever color you pass, opacity becomes partial "
                            + "coverage, and blend_mode is not valid. \"mask\" needs a "
                            + "layer that already has one (add_layer_mask). On an "
                            + "ADJUSTMENT layer a layer or colour-plane stroke paints the "
                            + "mask instead, whatever this says — a channel target is "
                            + "document state and is never rerouted.",
                    ],
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "eraser_stroke",
                "Erases along a polyline (same geometry as brush_stroke): pixels under the "
                    + "stroke become transparent. opacity is the eraser strength. With "
                    + "target: \"mask\" it hides through the layer's mask instead, leaving "
                    + "the pixels intact.",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] along the stroke, in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 1, "maxItems": 10_000,
                    ],
                    "size": [
                        "type": "number",
                        "description": "Stroke width in px (1-512, default 16).",
                    ],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "hardness": [
                        "type": "number", "minimum": 0, "maximum": 100,
                        "description": "Edge hardness in percent (default 100 = crisp). "
                            + "Below 100 the erase feathers out from hardness% of the "
                            + "radius to the rim.",
                    ],
                    "flow": flowProperty,
                    "spacing": spacingProperty,
                    "angle": angleProperty,
                    "roundness": roundnessProperty,
                    "layer": index,
                    "target": [
                        "type": "string",
                        "description": "What the stroke erases: " + targetVocabulary
                            + " \"layer\" makes the layer's own pixels transparent; every "
                            + "other target is coverage, painted BLACK, so the mask HIDES "
                            + "what the stroke covers (the pixels stay intact — undo it by "
                            + "brushing with brush_stroke and the same target), a colour "
                            + "plane goes toward 0, and a channel deselects there. opacity "
                            + "becomes partial coverage. \"mask\" needs a layer that "
                            + "already has one (add_layer_mask). On an ADJUSTMENT layer a "
                            + "layer or colour-plane stroke paints the mask instead.",
                    ],
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "clone_stamp",
                "Clones pixels from one part of the picture onto a layer — the Clone Stamp "
                    + "tool. A snapshot of the CURRENT flattened composite, displaced by "
                    + "(first point − source), is painted through a round-capped stroke "
                    + "along points, so what lands under the stroke comes from a region the "
                    + "same offset away: source_x,source_y is what appears under the FIRST "
                    + "point, and the offset stays fixed along the stroke (aligned cloning). "
                    + "Respects the active selection. Errors on an adjustment layer (no "
                    + "pixels to rewrite). This rewrites the layer's pixels, so a "
                    + "re-editable text, shape, or Live Photo layer drops its description "
                    + "(undo restores it).",
                [
                    "source_x": [
                        "type": "number",
                        "description": "Canvas x of the point cloned FROM — the pixels there "
                            + "land under the stroke's first point.",
                    ],
                    "source_y": [
                        "type": "number",
                        "description": "Canvas y of the point cloned FROM.",
                    ],
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] along the stroke, in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 1, "maxItems": 10_000,
                    ],
                    "size": [
                        "type": "number",
                        "description": "Stroke width in px (1-200, default 24).",
                    ],
                    "opacity": [
                        "type": "number", "minimum": 0, "maximum": 1,
                        "description": "Strength of the cloned paint (default 1).",
                    ],
                    "hardness": [
                        "type": "number", "minimum": 0, "maximum": 100,
                        "description": "Edge hardness in percent (default 100 = crisp). "
                            + "Below 100 the cloned paint feathers out from hardness% of "
                            + "the dab radius to the rim, blending it into the "
                            + "surroundings.",
                    ],
                    "flow": flowProperty,
                    "spacing": spacingProperty,
                    "angle": angleProperty,
                    "roundness": roundnessProperty,
                    "blend_mode": cloneBlendProperty,
                    "layer": index,
                    "document_id": docID,
                ], required: ["source_x", "source_y", "points"]),
            tool(
                "dodge_burn",
                "Lightens (dodge) or, with burn: true, darkens a layer's pixels where a "
                    + "round-capped stroke along points covers them — the Dodge / Burn tool. "
                    + "exposure is the strength and range picks the tones that move most: "
                    + "shadows, midtones (default), or highlights. Respects the active "
                    + "selection; repeat the stroke to build the effect up. Errors on an "
                    + "adjustment layer (edit its parameters instead). This rewrites the "
                    + "layer's pixels, so a re-editable text, shape, or Live Photo layer drops its description "
                    + "(undo restores it).",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] along the stroke, in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 1, "maxItems": 10_000,
                    ],
                    "size": [
                        "type": "number",
                        "description": "Stroke width in px (1-200, default 24).",
                    ],
                    "exposure": [
                        "type": "number", "minimum": 0, "maximum": 100,
                        "description": "Strength in percent (0-100, default 50).",
                    ],
                    "range": [
                        "type": "string",
                        "enum": ["shadows", "midtones", "highlights"],
                        "description": "Which tones the stroke moves most (default "
                            + "midtones).",
                    ],
                    "burn": [
                        "type": "boolean",
                        "description": "true darkens (burn) instead of lightening (dodge). "
                            + "Default false.",
                    ],
                    "hardness": [
                        "type": "number", "minimum": 0, "maximum": 100,
                        "description": "Edge hardness in percent (default 100 = crisp). "
                            + "Below 100 the effect feathers out from hardness% of the "
                            + "radius to the rim.",
                    ],
                    "flow": flowProperty,
                    "spacing": spacingProperty,
                    "angle": angleProperty,
                    "roundness": roundnessProperty,
                    "layer": index,
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "add_text",
                "Rasterizes text onto a layer's pixels — the characters become pixels and "
                    + "cannot be changed afterwards, so prefer add_text_layer when the text "
                    + "may need editing. x,y is the TOP-LEFT corner of the text block; long "
                    + "lines wrap at the canvas edge and \\n starts a new line. Returns the "
                    + "rendered text size so you can position follow-ups.",
                [
                    "text": ["type": "string"],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "size": [
                        "type": "number",
                        "description": "Font size in px (4-1000, default 48).",
                    ],
                    "font": [
                        "type": "string",
                        "description": "Font family or PostScript name (default: system font).",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000).",
                    ],
                    "layer": index,
                    "document_id": docID,
                ], required: ["text", "x", "y"]),
            tool(
                "add_text_layer",
                "Adds a RE-EDITABLE text layer above the active layer and selects it. The "
                    + "layer remembers the string, font, size, color, alignment, typography "
                    + "(weight, italic, tracking, leading, baseline shift, underline, "
                    + "strikethrough), wrap width and transform it was rendered from "
                    + "(get_document reports them, edit_text_layer changes them, "
                    + "transform_layer composes onto them, and they survive saving to .rz), "
                    + "unlike add_text which just bakes characters into pixels. x,y is the "
                    + "TOP-LEFT corner of the text block in canvas px (its origin in "
                    + "get_document; rounded to whole px for an untransformed block, kept "
                    + "exact under a transform), positioned exactly like add_text; \\n "
                    + "starts a new line and long lines wrap at wrap_width. Returns the new "
                    + "layer's index and bounds. NOTE: painting on the layer afterwards "
                    + "(brush, eraser, fill, gradient, add_text, apply_filter) drops the "
                    + "text and leaves plain pixels.",
                [
                    "text": ["type": "string"],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "size": [
                        "type": "number",
                        "description": "Font size in px (4-1000, default 48).",
                    ],
                    "font": [
                        "type": "string",
                        "description": "Installed font FAMILY name, e.g. \"Helvetica Neue\" "
                            + "or \"Times New Roman\" (not a PostScript face name). "
                            + "Default: the text tool's own default family.",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000).",
                    ],
                    "alignment": [
                        "type": "string",
                        "enum": TextLayerPayload.alignments,
                        "description": "How lines align within the text block (default "
                            + "left). The block stays anchored at x,y — only the lines "
                            + "inside it shift, so single-line text looks the same for all "
                            + "three values.",
                    ],
                    "weight": textWeightProperty,
                    "italic": textItalicProperty,
                    "underline": textUnderlineProperty,
                    "strikethrough": textStrikethroughProperty,
                    "tracking": textTrackingProperty,
                    "leading": textLeadingProperty,
                    "baseline_shift": textBaselineProperty,
                    "transform": transformProperty(
                        "applied to the text before it is placed at x,y"),
                    "wrap_width": [
                        "type": "number",
                        "description": "px; the block wraps at this SOURCE-space width and "
                            + "remembers it (box_width); 0 = point text that never wraps "
                            + "(at most 100000 px, the app's own editor cap). Default: "
                            + "from x to the canvas's right edge.",
                    ],
                    "document_id": docID,
                ], required: ["text", "x", "y"]),
            tool(
                "edit_text_layer",
                "Re-renders a text layer made by add_text_layer (or by the app's text tool) "
                    + "from changed parameters: pass any subset of text, font, size, color, "
                    + "alignment, weight, italic, underline, strikethrough, tracking, "
                    + "leading, baseline_shift, wrap_width and transform, and everything you "
                    + "omit keeps the layer's current value. The layer keeps its position "
                    + "(the block is re-laid-out from its origin, keeping its transform "
                    + "unless you pass one, so the bounds follow the new text), its "
                    + "opacity, blend mode, mask, style and stacking. Errors when the target "
                    + "layer is not a text layer — add_text_layer makes one. Returns the "
                    + "resulting bounds and the layer's full text object.",
                [
                    "layer": index,
                    "text": ["type": "string"],
                    "size": [
                        "type": "number",
                        "description": "Font size in px (4-1000).",
                    ],
                    "font": [
                        "type": "string",
                        "description": "Installed font FAMILY name (not a PostScript face "
                            + "name).",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA.",
                    ],
                    "alignment": [
                        "type": "string",
                        "enum": TextLayerPayload.alignments,
                        "description": "How lines align within the text block; omit to keep "
                            + "the layer's current alignment.",
                    ],
                    "weight": textWeightProperty,
                    "italic": textItalicProperty,
                    "underline": textUnderlineProperty,
                    "strikethrough": textStrikethroughProperty,
                    "tracking": textTrackingProperty,
                    "leading": textLeadingProperty,
                    "baseline_shift": textBaselineProperty,
                    "transform": transformProperty(
                        "replacing the layer's current one (default: keep it)"),
                    "wrap_width": [
                        "type": "number",
                        "description": "px; the block wraps at this SOURCE-space width and "
                            + "remembers it (box_width); 0 = point text that never wraps "
                            + "(at most 100000 px, the app's own editor cap). Default: keep "
                            + "the layer's stored width — a layer saved before "
                            + "widths were stored (box_width null in get_document) re-wraps "
                            + "from its origin to the canvas's right edge, as this tool "
                            + "always did (the app's own editor caps that legacy default at "
                            + "600 px; the two differ only for lines wider than that), and "
                            + "stores that width from then on.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "add_shape_layer",
                "Adds a RE-EDITABLE shape layer above the active layer and selects it — "
                    + "the same parametric layers the app's shape tools drag out: the kind, "
                    + "box size, fill, stroke and corner radius become the layer's "
                    + "description and the pixels are only their rendering. x,y is the "
                    + "TOP-LEFT corner of the shape box in canvas px (its origin in "
                    + "get_document) and w,h its size; the shape lands exactly there (the "
                    + "layer's raster is a few px larger on every side for stroke overhang "
                    + "and antialiasing), through transform when one is given. rect and ellipse "
                    + "take fill and/or stroke — pass at least one; a line is stroke-only "
                    + "and runs across the box's diagonal, top-left to bottom-right, or "
                    + "bottom-left to top-right with flipped: true. Returns the new layer's "
                    + "index and name. NOTE: painting on the layer afterwards drops the "
                    + "shape description and leaves plain pixels.",
                [
                    "kind": [
                        "type": "string",
                        "enum": ShapeLayerPayload.kinds,
                        "description": "What to draw: rect, ellipse, or line.",
                    ],
                    "x": [
                        "type": "number",
                        "description": "Shape box top-left x, canvas px.",
                    ],
                    "y": [
                        "type": "number",
                        "description": "Shape box top-left y, canvas px.",
                    ],
                    "w": [
                        "type": "number",
                        "description": "Shape box width in px (>= 1; a line may have 0 on "
                            + "one axis).",
                    ],
                    "h": [
                        "type": "number",
                        "description": "Shape box height in px (>= 1; a line may have 0 on "
                            + "one axis).",
                    ],
                    "flipped": [
                        "type": "boolean",
                        "description": "Line only (default false): false runs top-left to "
                            + "bottom-right across the box, true bottom-left to top-right.",
                    ],
                    "fill": [
                        "type": "string",
                        "description": "Hex fill color, #RRGGBB or #RRGGBBAA; omit for no "
                            + "fill. Ignored for lines.",
                    ],
                    "stroke": [
                        "type": "string",
                        "description": "Hex stroke color, #RRGGBB or #RRGGBBAA; omit for no "
                            + "stroke (a line requires one).",
                    ],
                    "stroke_width": [
                        "type": "number",
                        "description": "Stroke width in px, centered on the path (0-200, "
                            + "default 2; a line needs at least 1).",
                    ],
                    "radius": [
                        "type": "number",
                        "description": "Rect corner radius in px (default 0 = square "
                            + "corners; ignored by ellipse and line).",
                    ],
                    "transform": transformProperty(
                        "applied to the box before it is placed — the box's top-left stays "
                            + "at x,y"),
                    "document_id": docID,
                ], required: ["kind", "x", "y", "w", "h"]),
            tool(
                "edit_shape_layer",
                "Changes an existing SHAPE layer's description and re-renders its pixels "
                    + "— the box, fill, stroke, stroke width, corner radius, line "
                    + "direction or transform — as one undo step, the way double-clicking "
                    + "the layer in the app reopens it. Works only on layers get_document "
                    + "reports a \"shape\" object for; the kind (rect / ellipse / line) is "
                    + "fixed at creation. Omitted arguments keep the layer's current values "
                    + "(x,y default to its origin, transform to its current map); the mask "
                    + "and style ride along. Pass fill or stroke as \"\" to remove that "
                    + "paint (at least one visible paint must remain).",
                [
                    "layer": index,
                    "x": [
                        "type": "number",
                        "description": "New shape box top-left x, canvas px (default: keep).",
                    ],
                    "y": [
                        "type": "number",
                        "description": "New shape box top-left y, canvas px (default: keep).",
                    ],
                    "w": [
                        "type": "number",
                        "description": "New box width in px (default: keep).",
                    ],
                    "h": [
                        "type": "number",
                        "description": "New box height in px (default: keep).",
                    ],
                    "flipped": [
                        "type": "boolean",
                        "description": "Line only: false runs top-left to bottom-right "
                            + "across the box, true bottom-left to top-right (default: "
                            + "keep).",
                    ],
                    "fill": [
                        "type": "string",
                        "description": "Hex fill color, #RRGGBB or #RRGGBBAA; \"\" removes "
                            + "the fill (default: keep). Ignored for lines.",
                    ],
                    "stroke": [
                        "type": "string",
                        "description": "Hex stroke color, #RRGGBB or #RRGGBBAA; \"\" removes "
                            + "the stroke (default: keep; a line requires one).",
                    ],
                    "stroke_width": [
                        "type": "number",
                        "description": "Stroke width in px, centered on the path (0-200; "
                            + "default: keep).",
                    ],
                    "radius": [
                        "type": "number",
                        "description": "Rect corner radius in px (default: keep; ignored by "
                            + "ellipse and line).",
                    ],
                    "transform": transformProperty(
                        "replacing the layer's current one (default: keep it)"),
                    "document_id": docID,
                ]),
            tool(
                "add_live_photo_layer",
                "Adds an Apple LIVE PHOTO as a new layer above the active one and selects "
                    + "it. A Live Photo is a photo plus a short video sharing one name in one "
                    + "folder (IMG_0001.HEIC and IMG_0001.MOV) — pass the path of either "
                    + "half. The layer shows the key frame (the photo itself, at full "
                    + "resolution) and remembers which moment it is showing, so "
                    + "set_live_photo_frame can pick another one later; get_document reports "
                    + "that as a live_photo object. NOTE: painting on the layer afterwards "
                    + "(brush, eraser, fill, gradient, add_text, apply_filter) drops the link "
                    + "and leaves plain pixels.",
                [
                    "path": [
                        "type": "string",
                        "description": "Absolute or ~ path to either half of the Live Photo.",
                    ],
                    "time": [
                        "type": "number",
                        "description": "Moment to show, in seconds from the start of the "
                            + "video (default: the key frame). Clamped to the video's "
                            + "length.",
                    ],
                    "name": [
                        "type": "string",
                        "description": "Layer name (default: the file's name).",
                    ],
                    "layer": [
                        "type": "integer",
                        "description": "Insert above this layer index; omit for the active "
                            + "layer.",
                    ],
                    "document_id": docID,
                ], required: ["path"]),
            tool(
                "set_live_photo_frame",
                "Shows a different moment of a live photo layer's video — the layer's pixels "
                    + "are re-rendered from that frame as one undo step, and everything else "
                    + "about the layer (name, position, opacity, blend mode, mask, style and "
                    + "transform) is kept. "
                    + "Frames are scaled to the layer's size, and the key frame is the "
                    + "full-resolution photo itself, so times away from it are softer. "
                    + "Errors when the target layer is not a live photo layer "
                    + "(add_live_photo_layer makes one) or when its video file has been "
                    + "moved away. Returns the moment that actually landed: the time is "
                    + "clamped to the video and snaps to the key frame when it lands within "
                    + "a frame of it.",
                [
                    "time": [
                        "type": "number",
                        "description": "Seconds from the start of the video; "
                            + "get_document's live_photo object reports duration and "
                            + "key_time.",
                    ],
                    "layer": index,
                    "document_id": docID,
                ], required: ["time"]),
            tool(
                "select_rect",
                "Selects a rectangle (canvas coordinates). Selections confine "
                    + "brush/eraser strokes, fill, and gradient, and define Crop.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "select_ellipse",
                "Selects an ellipse inscribed in the given rectangle.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "select_polygon",
                "Selects a polygon through the given vertices (at least 3, "
                    + "closed automatically).",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] polygon vertices in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 3, "maxItems": 10_000,
                    ],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "select_magic_wand",
                "Selects the region of similar color around a seed point, sampled "
                    + "from the flattened composite (what you see in a render). "
                    + "tolerance is the max per-channel difference (0-255, default 32); "
                    + "contiguous (default true) limits to the connected region.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "tolerance": ["type": "integer", "minimum": 0, "maximum": 255],
                    "contiguous": ["type": "boolean"],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["x", "y"]),
            tool(
                "select_subject",
                "Selects the prominent foreground subjects — people, animals, "
                    + "objects — that macOS's Vision segmentation finds in the flattened "
                    + "composite. This is the same model behind Preview's Copy Subject, "
                    + "so it needs no seed point and no tolerance, unlike "
                    + "select_magic_wand. Mirrors Select > Select Subject. Omit instance "
                    + "to select every subject at once; pass instance (1-based) for a "
                    + "single one. Every result reports \"instances\", the number of "
                    + "subjects found, so you can select each in turn and compare their "
                    + "bounds to tell them apart.",
                [
                    "instance": [
                        "type": "integer", "minimum": 1,
                        "description": "Which single subject to select (1-based). "
                            + "Omit to select all of them.",
                    ],
                    "mode": selectionMode,
                    "document_id": docID,
                ]),
            tool(
                "deselect", "Clears the selection.", ["document_id": docID]),
            tool(
                "modify_selection",
                "Transforms the current selection (errors when nothing is selected): "
                    + "invert selects the complement over the canvas; feather "
                    + "Gaussian-softens the selection edge by radius px, so later "
                    + "fills, gradients, and strokes fade out across it; grow/shrink "
                    + "move the selection edge outward/inward by radius px (corners "
                    + "round into arcs); border replaces the selection with a band "
                    + "width px wide straddling its edge; smooth rounds corners and "
                    + "evens out jagged edges without moving long straight ones. An "
                    + "empty result clears the selection.",
                [
                    "operation": [
                        "type": "string",
                        "enum": ["invert", "feather", "grow", "shrink", "border", "smooth"],
                    ],
                    "radius": [
                        "type": "number",
                        "description": "Radius in px (0-250; required for feather, grow, "
                            + "shrink, and smooth).",
                    ],
                    "width": [
                        "type": "number",
                        "description": "Band width in px (0-250; required for border).",
                    ],
                    "document_id": docID,
                ], required: ["operation"]),
            tool(
                "fill",
                "Bucket fill: flood-fills the similar-color region around the seed "
                    + "point on a layer's own pixels with a color. Respects the active "
                    + "selection. tolerance as in select_magic_wand.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000).",
                    ],
                    "tolerance": ["type": "integer", "minimum": 0, "maximum": 255],
                    "contiguous": ["type": "boolean"],
                    "layer": index,
                    "target": [
                        "type": "string",
                        "description": "What the fill lands on: " + targetVocabulary
                            + " (\"mask\" is not one of them here.) A plane or channel "
                            + "target holds COVERAGE, not color, so the color enters as "
                            + "its gray (its luma) and its alpha is the strength."
                            + alphaWriteNote,
                    ],
                    "document_id": docID,
                ], required: ["x", "y"]),
            tool(
                "gradient",
                "Paints a two-color gradient over a layer (the whole layer, or the "
                    + "active selection if one exists). Linear runs along "
                    + "(x0,y0)->(x1,y1); radial spreads from (x0,y0) with radius to "
                    + "(x1,y1). end_color defaults to transparent (a fade-out).",
                [
                    "x0": ["type": "number"], "y0": ["type": "number"],
                    "x1": ["type": "number"], "y1": ["type": "number"],
                    "start_color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA.",
                    ],
                    "end_color": [
                        "type": "string",
                        "description": "Hex color; omit to fade to transparent.",
                    ],
                    "shape": ["type": "string", "enum": ["linear", "radial"]],
                    "layer": index,
                    "target": [
                        "type": "string",
                        "description": "What the ramp lands on: " + targetVocabulary
                            + " (\"mask\" is not one of them here.) On a plane or a "
                            + "channel both colors enter as their grays — coverage, not "
                            + "color — with their alpha as the strength."
                            + alphaWriteNote,
                    ],
                    "document_id": docID,
                ], required: ["x0", "y0", "x1", "y1", "start_color"]),
            tool(
                "clear_selection",
                "Erases the active selection out of a layer: the selected pixels lose "
                    + "their color and become transparent, in proportion to the selection's "
                    + "coverage, so a feathered selection cuts a soft-edged hole. Only the "
                    + "one layer changes — whatever sits below it shows through. Errors "
                    + "when nothing is selected; make a selection with the select_* tools "
                    + "first.",
                [
                    "layer": index,
                    "document_id": docID,
                ]),
            // Channels — saved selections, per-plane arithmetic (the
            // Channels panel, Select > Save/Load Selection, Image > Apply
            // Image… / Calculations…).
            tool(
                "list_channels",
                "Lists the document's ALPHA CHANNELS: named canvas-sized coverage planes "
                    + "(0 = out, 255 = in, in between = a soft edge) that are saved "
                    + "selections. A channel is never part of the picture — its overlay "
                    + "colour, opacity and color_indicates only say how the app draws it as "
                    + "a rubylith. Use the index or the name wherever a tool takes "
                    + "`channel`.",
                ["document_id": docID]),
            tool(
                "add_channel",
                "Adds an alpha channel — the Channels panel's New Channel, and Save "
                    + "Selection as Channel. from: \"empty\" (default) an all-zero channel; "
                    + "\"selection\" the current selection's coverage (errors when nothing "
                    + "is selected); \"layer_alpha\" a layer's transparency; \"layer_mask\" "
                    + "a layer's mask; \"plane\" one colour plane of the flattened "
                    + "composite. One undo step.",
                [
                    "name": [
                        "type": "string",
                        "description": "Channel name (default the next \"Alpha N\").",
                    ],
                    "from": [
                        "type": "string",
                        "enum": ["empty", "selection", "layer_alpha", "layer_mask", "plane"],
                    ],
                    "layer": index,
                    "plane": [
                        "type": "string",
                        "enum": ["red", "green", "blue", "alpha", "luma"],
                        "description": "Which plane, for from: \"plane\" (default luma).",
                    ],
                    "overlay_color": [
                        "type": "string",
                        "description": "Rubylith colour, #RRGGBB (default #ff0000). Display "
                            + "only.",
                    ],
                    "overlay_opacity": [
                        "type": "number", "minimum": 0, "maximum": 1,
                        "description": "Rubylith opacity 0-1 (default 0.5). Display only.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "delete_channel",
                "Deletes an alpha channel — the channels row menu's Delete Channel. One "
                    + "undo step.",
                [
                    "channel": [
                        "type": "string",
                        "description": "Channel name or index (list_channels shows both).",
                    ],
                    "document_id": docID,
                ], required: ["channel"]),
            tool(
                "duplicate_channel",
                "Copies an alpha channel — the channels row menu's Duplicate Channel. The "
                    + "copy is named \"<name> copy\" and lands immediately after the "
                    + "original, so the indices below it shift down by one. One undo step.",
                [
                    "channel": [
                        "type": "string",
                        "description": "Channel name or index (list_channels shows both).",
                    ],
                    "document_id": docID,
                ], required: ["channel"]),
            tool(
                "rename_channel",
                "Renames an alpha channel — the channels row's double-click rename. Names "
                    + "need not be unique; the first match wins wherever a name is used.",
                [
                    "channel": [
                        "type": "string",
                        "description": "Channel name or index.",
                    ],
                    "name": ["type": "string", "description": "The new name."],
                    "document_id": docID,
                ], required: ["channel", "name"]),
            tool(
                "set_channel_options",
                "Changes an alpha channel's name and rubylith — Channel Options…. The "
                    + "rubylith is DISPLAY state: it never changes a byte of the channel's "
                    + "coverage. color_indicates \"masked\" (the default, and Quick Mask's "
                    + "polarity) washes where the channel is BLACK; \"selected\" washes "
                    + "where it is white. Omitted properties stay as they are; one undo "
                    + "step.",
                [
                    "channel": [
                        "type": "string",
                        "description": "Channel name or index.",
                    ],
                    "name": ["type": "string"],
                    "overlay_color": [
                        "type": "string", "description": "Rubylith colour, #RRGGBB.",
                    ],
                    "overlay_opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "color_indicates": ["type": "string", "enum": ["masked", "selected"]],
                    "document_id": docID,
                ], required: ["channel"]),
            tool(
                "invert_channel",
                "Inverts an alpha channel's coverage (255 − v per pixel) — the channels row "
                    + "menu's Invert Channel. What it selected it now excludes. One undo "
                    + "step.",
                [
                    "channel": [
                        "type": "string",
                        "description": "Channel name or index.",
                    ],
                    "document_id": docID,
                ], required: ["channel"]),
            tool(
                "load_selection",
                "Loads a plane as the selection — Select > Load Selection…, and ⌘-clicking "
                    + "a channel row or a layer thumbnail in the app. Sources: an alpha "
                    + "channel (default), a layer's transparency, a layer's mask, or one "
                    + "colour plane of the flattened composite. A selection is not an edit: "
                    + "no undo step. An all-zero source is not an error — it clears the "
                    + "selection and reports selection_empty.",
                [
                    "from": [
                        "type": "string",
                        "enum": ["channel", "layer_alpha", "layer_mask", "plane"],
                    ],
                    "channel": [
                        "type": "string",
                        "description": "Channel name or index, for from: \"channel\".",
                    ],
                    "layer": index,
                    "plane": [
                        "type": "string",
                        "enum": ["red", "green", "blue", "alpha", "luma"],
                        "description": "Which plane, for from: \"plane\" (default luma).",
                    ],
                    "mode": selectionMode,
                    "invert": [
                        "type": "boolean",
                        "description": "Load the complement instead (default false).",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "save_selection",
                "Writes the current selection into an alpha channel — Select > Save "
                    + "Selection…. With `name` (or neither) it creates a new channel; with "
                    + "`channel` it combines into that existing one, where `mode` says how. "
                    + "Errors when nothing is selected. One undo step.",
                [
                    "name": [
                        "type": "string",
                        "description": "New channel's name (default the next \"Alpha N\"). "
                            + "Ignored when `channel` is given.",
                    ],
                    "channel": [
                        "type": "string",
                        "description": "Existing channel name or index to combine into.",
                    ],
                    // NOT the shared `selectionMode`: this tool writes the
                    // selection INTO a channel, so the mode combines the two
                    // the other way round and an empty result leaves an empty
                    // channel rather than deselecting.
                    "mode": [
                        "type": "string",
                        "enum": ["replace", "add", "subtract", "intersect"],
                        "description": "How the selection combines into the existing "
                            + "`channel` (default replace, which overwrites it). add unions, "
                            + "subtract removes the selection from the channel's coverage, "
                            + "intersect keeps the overlap. Ignored without `channel`. The "
                            + "current selection is never changed.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "apply_image",
                "Image > Apply Image…: blends ONE source plane onto the target — a layer's "
                    + "pixels (as one colour, plane for plane), one colour plane of them, or "
                    + "an alpha channel — at an opacity. The source "
                    + "is a layer or the flattened composite (\"merged\"), read as its whole "
                    + "colour image, one plane, or a channel; source_plane \"rgb\" against a "
                    + "single-plane target uses the source's luma. Writes layer pixels "
                    + "destructively for a layer or plane target, so a re-editable text, "
                    + "shape or Live Photo layer drops its description. One undo step.",
                [
                    "source": [
                        "type": "string",
                        "description": "\"merged\" (default) or a layer index.",
                    ],
                    "source_plane": [
                        "type": "string",
                        "description": "\"rgb\" (default), \"red\", \"green\", \"blue\", "
                            + "\"luma\", \"alpha\", or an alpha channel's name.",
                    ],
                    "invert": [
                        "type": "boolean",
                        "description": "Invert the source plane first (default false).",
                    ],
                    "blend_mode": [
                        "type": "string", "enum": blendNames,
                        "description": "Any mode onto \"layer\", which blends the three "
                            + "planes as ONE colour. Onto a single plane or a channel the "
                            + "four HSL modes (Hue, Saturation, Color, Luminosity) are "
                            + "refused: they are defined over an RGB triple and say nothing "
                            + "about one 8-bit plane.",
                    ],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "target": [
                        "type": "string",
                        "description": "\"layer\" (default), \"red\"/\"green\"/\"blue\"/"
                            + "\"alpha\", or \"channel:<name>\".",
                    ],
                    "layer": index,
                    "document_id": docID,
                ]),
            tool(
                "calculations",
                "Image > Calculations…: blends TWO source planes into a new plane, which "
                    + "becomes a new alpha channel (default) or the selection. Source 1 is "
                    + "the blend layer and source 2 the base it is applied to (Photoshop's "
                    + "convention). Each source is a layer or \"merged\", one of its planes "
                    + "or a channel, optionally inverted. A new channel is one undo step; a "
                    + "selection is not an edit at all.",
                [
                    "source1": [
                        "type": "string",
                        "description": "\"merged\" (default) or a layer index.",
                    ],
                    "source1_plane": [
                        "type": "string",
                        "description": "\"rgb\" (default), a colour plane, or a channel name.",
                    ],
                    "invert1": ["type": "boolean"],
                    "source2": [
                        "type": "string",
                        "description": "\"merged\" (default) or a layer index.",
                    ],
                    "source2_plane": [
                        "type": "string",
                        "description": "\"rgb\" (default), a colour plane, or a channel name.",
                    ],
                    "invert2": ["type": "boolean"],
                    "blend_mode": [
                        "type": "string", "enum": planeBlendNames,
                        "description": "The result is ONE plane, so the four HSL modes (Hue, "
                            + "Saturation, Color, Luminosity) are not offered — they are "
                            + "defined over an RGB triple. Every other mode applies. (Onto a "
                            + "whole LAYER, apply_image does take them.)",
                    ],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "result": ["type": "string", "enum": ["new_channel", "selection"]],
                    "name": [
                        "type": "string",
                        "description": "New channel's name (default the next \"Alpha N\").",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "add_luminosity_masks",
                "Select > Add Luminosity Masks: appends nine channels built from the "
                    + "composite's Rec. 709 luma L — \"Lights 1\"..\"Lights 3\" (L, L², L³), "
                    + "\"Darks 1\"..\"Darks 3\" ((1−L), (1−L)², (1−L)³) and \"Midtones "
                    + "1\"..\"Midtones 3\" (the complement of each squared pair, peaking at "
                    + "mid grey) — the photographer's tone-selection set. Load one with "
                    + "load_selection. Refused when nine more channels would not fit. One "
                    + "undo step.",
                ["document_id": docID]),
            tool(
                "rotate",
                "Rotates the whole document clockwise. Re-editable text, shape and Live "
                    + "Photo layers stay re-editable: the op composes into their "
                    + "descriptions (a later edit lands in place).",
                [
                    "degrees": ["type": "integer", "enum": [90, 180, 270, -90]],
                    "document_id": docID,
                ], required: ["degrees"]),
            tool(
                "flip",
                "Flips the whole document. Re-editable text, shape and Live Photo layers "
                    + "stay re-editable: the op composes into their descriptions.",
                [
                    "axis": ["type": "string", "enum": ["horizontal", "vertical"]],
                    "document_id": docID,
                ], required: ["axis"]),
            tool(
                "crop",
                "Crops the document to a rectangle (canvas coordinates, origin top-left). "
                    + "A nonzero angle straightens first — the Crop tool's straighten "
                    + "slider: every layer — and every alpha channel, so saved selections "
                    + "keep lining up — is rotated by −angle about the rect's center, "
                    + "then the canvas is cropped, as one undo step. Straightening "
                    + "resamples every layer's pixels, so re-editable text, shape and Live "
                    + "Photo layers rasterize — their descriptions drop, and the result "
                    + "names which (undo restores them). At angle 0 the crop only moves "
                    + "the canvas window and every description stays valid.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "angle": [
                        "type": "number", "minimum": -45, "maximum": 45,
                        "description": "Straighten angle in degrees (-45 to 45, default 0): "
                            + "the content rotates by −angle, so a positive angle turns the "
                            + "picture counter-clockwise on screen — the same sign as the "
                            + "app's Straighten field.",
                    ],
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "image_size",
                "Scales the whole document to a new size (max 100 megapixels). Re-editable "
                    + "text, shape and Live Photo layers stay re-editable: the scale composes "
                    + "into their descriptions, and text and shapes re-render crisply. Alpha "
                    + "channels are canvas-sized and are resampled too, so a document "
                    + "carrying many of them is refused past the format's total "
                    + "channel-pixel budget (900 million): the error names how many the new "
                    + "canvas would hold, and delete_channel is the way out.",
                [
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "filter": [
                        "type": "string",
                        "enum": ["nearest", "bilinear", "catmull-rom", "lanczos3"],
                        "description": "Resampling filter, default lanczos3.",
                    ],
                    "document_id": docID,
                ], required: ["width", "height"]),
            tool(
                "canvas_size",
                "Resizes the canvas WITHOUT scaling the pixels; the anchor pins the existing "
                    + "content (like Photoshop's Canvas Size). Layers keep their pixels and "
                    + "can extend outside the canvas; alpha channels are padded with 0. "
                    + "GROWING the canvas grows every channel with it, so the same total "
                    + "channel-pixel budget image_size names can refuse it — delete channels "
                    + "and retry.",
                [
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "anchor": [
                        "type": "string",
                        "enum": [
                            "top-left", "top", "top-right", "left", "center", "right",
                            "bottom-left", "bottom", "bottom-right",
                        ],
                        "description": "Where the existing content is pinned; default center.",
                    ],
                    "document_id": docID,
                ], required: ["width", "height"]),
            tool("undo", "Undoes the most recent edit.", ["document_id": docID]),
            tool("redo", "Redoes the most recently undone edit.", ["document_id": docID]),
            tool(
                "save_copy",
                "Exports the document to a file without changing the open document. "
                    + "Format comes from the extension unless given explicitly. "
                    + "rz writes the full layered document (layers, masks, metadata); "
                    + "raster formats flatten.",
                [
                    "path": ["type": "string"],
                    "format": [
                        "type": "string",
                        "enum": ["rz", "png", "jpeg", "tiff", "bmp", "gif", "webp"],
                    ],
                    "jpeg_quality": ["type": "integer", "minimum": 1, "maximum": 100],
                    "document_id": docID,
                ], required: ["path"]),
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog)
        return String(decoding: data, as: UTF8.self)
    }
}
