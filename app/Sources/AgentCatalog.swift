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
                    + "and clipped flag (see set_layer_clipped). "
                    + "A re-editable TEXT layer also reports a text object (string, font, size, "
                    + "color, alignment) — those are the layers edit_text_layer can change; a "
                    + "layer without that key is plain pixels. An ADJUSTMENT layer reports "
                    + "is_adjustment true plus an adjustment object (op, params) — those are "
                    + "the layers edit_adjustment_layer can change. Layer index 0 is the bottom "
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
                    + "scales act around a pivot (the centre of the layer's CURRENT bounds by "
                    + "default), then the translation is added; the layer is resampled once "
                    + "into the outward-rounded bounding box of its transformed corners, so "
                    + "its offset AND size both change, and it may end up extending past the "
                    + "canvas. The canvas and every other layer are untouched, and a layer "
                    + "mask rides along, resampled identically. Pass at least one of rotate, "
                    + "scale, scale_x, scale_y, translate_x, translate_y; the result reports "
                    + "the layer's new bounds so you can verify placement. For whole-document "
                    + "geometry use rotate / flip / image_size instead. NOTE: this rewrites "
                    + "the layer's pixels, so on a re-editable TEXT layer it drops the text "
                    + "description (undo restores it) — to just MOVE such a layer and keep "
                    + "its text, set offset_x / offset_y with set_layer_properties.",
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
                            + "bounds. pivot_x / pivot_y override it.",
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
                    "layer": index,
                    "target": [
                        "type": "string",
                        "enum": ["layer", "mask"],
                        "description": "What the stroke paints: \"layer\" (default) the "
                            + "layer's own pixels, \"mask\" the layer's mask, where the "
                            + "stroke REVEALS what it covers. A mask is coverage, not color, "
                            + "so a mask stroke is forced to WHITE whatever color you pass, "
                            + "and opacity becomes partial coverage. The layer must already "
                            + "have a mask (add_layer_mask). On an ADJUSTMENT layer every "
                            + "stroke paints the mask, whatever this says.",
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
                    "layer": index,
                    "target": [
                        "type": "string",
                        "enum": ["layer", "mask"],
                        "description": "What the stroke erases: \"layer\" (default) makes the "
                            + "layer's own pixels transparent, \"mask\" paints the layer's "
                            + "mask so it HIDES what the stroke covers while the pixels stay "
                            + "intact (undo it by brushing the mask with target: \"mask\"). "
                            + "A mask is coverage, not color, so a mask stroke is forced to "
                            + "BLACK, and opacity becomes partial coverage. The layer must "
                            + "already have a mask (add_layer_mask). On an ADJUSTMENT layer "
                            + "every stroke paints the mask, whatever this says.",
                    ],
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
                    + "layer remembers the string, font, size, color and alignment it was "
                    + "rendered from (get_document reports them, edit_text_layer changes "
                    + "them, and they survive saving to .rz), unlike add_text which just "
                    + "bakes characters into pixels. x,y is the TOP-LEFT corner of the text "
                    + "block, positioned exactly like add_text; \\n starts a new line and "
                    + "long lines wrap at wrap_width. Returns the new layer's index and "
                    + "bounds. NOTE: painting on the layer afterwards (brush, eraser, fill, "
                    + "gradient, add_text, apply_filter) drops the text and leaves plain "
                    + "pixels.",
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
                    "wrap_width": [
                        "type": "number",
                        "description": "Width in px the lines wrap at; default is from x to "
                            + "the canvas's right edge.",
                    ],
                    "document_id": docID,
                ], required: ["text", "x", "y"]),
            tool(
                "edit_text_layer",
                "Re-renders a text layer made by add_text_layer (or by the app's text tool) "
                    + "from changed parameters: pass any subset of text, font, size, color, "
                    + "alignment and wrap_width, and everything you omit keeps the layer's "
                    + "current value. The layer keeps its position (the text block is "
                    + "re-laid-out from the same top-left corner, so the bounds follow the "
                    + "new text), its opacity, blend mode and stacking. Errors when the "
                    + "target layer is not a text layer — add_text_layer makes one. Returns "
                    + "the resulting bounds. wrap_width is not stored on the layer, so "
                    + "omitting it re-wraps at the canvas's right edge; pass it to keep a "
                    + "narrower block narrow.",
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
                    "wrap_width": [
                        "type": "number",
                        "description": "Width in px the lines wrap at.",
                    ],
                    "document_id": docID,
                ]),
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
            tool(
                "rotate", "Rotates the whole document clockwise.",
                [
                    "degrees": ["type": "integer", "enum": [90, 180, 270, -90]],
                    "document_id": docID,
                ], required: ["degrees"]),
            tool(
                "flip", "Flips the whole document.",
                [
                    "axis": ["type": "string", "enum": ["horizontal", "vertical"]],
                    "document_id": docID,
                ], required: ["axis"]),
            tool(
                "crop",
                "Crops the document to a rectangle (canvas coordinates, origin top-left).",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "image_size",
                "Scales the whole document to a new size (max 100 megapixels).",
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
                    + "can extend outside the canvas.",
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
