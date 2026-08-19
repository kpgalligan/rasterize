import AVFoundation
import AppKit

/// The two files an Apple LIVE PHOTO is made of, as they sit on disk: a still
/// image and the short motion clip shot around it. Photos exports them as a
/// pair sharing one basename in one folder (`IMG_0001.HEIC` + `IMG_0001.MOV`,
/// or `.JPG` + `.MOV` in "most compatible" mode), which is exactly how
/// `LivePhoto.locate` finds the partner of whichever half the user opened. A
/// bare movie is a legitimate source too — it simply has no still.
struct LivePhotoSource {
    let video: URL
    /// nil for a bare movie: the frames are then all there is.
    let still: URL?
}

/// What a LIVE PHOTO LAYER's pixels are: one frame of a Live Photo, named by
/// the files it came from and the moment it was taken at. Like a text
/// layer's description this is the source of truth and the raster only its
/// cache, and it is stored as JSON in the core's opaque per-layer metadata
/// slot — the core copies and persists those bytes without ever parsing
/// them, so the schema lives entirely on this side of the FFI.
///
/// JSON shape: `{"type":"live_photo","version":1,"video":<path>,
/// "still":<path>?,"time":<s>,"key_time":<s>,"duration":<s>,
/// "width":<px>,"height":<px>}`.
///
/// The two paths are ABSOLUTE and are not copied into the document: a saved
/// `.rz` remembers where the Live Photo lived, and moving or deleting those
/// files leaves the layer's pixels intact but makes choosing another frame
/// impossible — the same graceful degradation a text layer gets when its
/// font is not installed.
struct LivePhotoPayload: Codable, Equatable {
    /// The only `type` this app understands; anything else (or nothing)
    /// means the layer's metadata was written by something that is not a
    /// live photo layer, and the layer is plain pixels.
    static let typeName = "live_photo"
    /// The only `version` this app understands. A future schema change bumps
    /// it, and older builds then read those layers as plain rasters — the
    /// graceful degradation the format is designed for.
    static let currentVersion = 1

    var type: String
    var version: Int
    /// Absolute path of the motion clip every frame is decoded from.
    var video: String
    /// Absolute path of the still photo, when the pair has one.
    var still: String?
    /// The displayed moment, in seconds from the start of the clip.
    var time: Double
    /// The moment the still photo was taken (the clip's
    /// `still-image-time` metadata, 0 when it carries none) — the frame a
    /// layer shows until someone picks another, and the one position on the
    /// timeline where the FULL-RESOLUTION still is used instead of a video
    /// frame.
    var keyTime: Double
    var duration: Double
    /// The layer's pixel size: the still's when there is a still, else the
    /// clip's own frame size. Every frame is rendered to it, so scrubbing
    /// never changes the layer's geometry (and never drops its mask).
    var width: Int
    var height: Int

    enum CodingKeys: String, CodingKey {
        case type, version, video, still, time, duration, width, height
        case keyTime = "key_time"
    }

    init(
        video: URL, still: URL?, time: Double, keyTime: Double, duration: Double,
        width: Int, height: Int
    ) {
        self.type = Self.typeName
        self.version = Self.currentVersion
        self.video = video.path
        self.still = still?.path
        self.time = time
        self.keyTime = keyTime
        self.duration = duration
        self.width = width
        self.height = height
    }

    var videoURL: URL { URL(fileURLWithPath: video) }
    var stillURL: URL? { still.map { URL(fileURLWithPath: $0) } }

    /// True while the displayed frame IS the still photo: the clip's frames
    /// are typically a fraction of the still's resolution, so at the key
    /// moment — the same moment, by definition — the full-resolution photo
    /// is what the layer shows.
    var showsStill: Bool {
        still != nil && abs(time - keyTime) <= LivePhoto.keySnapTolerance
    }

    /// The same payload displaying `seconds`: clamped into the clip, and
    /// snapped to the key moment when it lands within a frame of it, so
    /// dragging a slider back to the start of the timeline reliably restores
    /// the full-resolution still.
    func settingTime(_ seconds: Double) -> LivePhotoPayload {
        var updated = self
        guard seconds.isFinite else { return updated }
        let clamped = min(max(seconds, 0), duration)
        updated.time =
            abs(clamped - keyTime) <= LivePhoto.keySnapTolerance ? keyTime : clamped
        return updated
    }

    /// Whether the frames can still be decoded — false once the clip has
    /// been moved away or deleted, which is what disables "Select Frame…".
    var sourceExists: Bool {
        FileManager.default.fileExists(atPath: video)
    }

    /// The JSON to store as the layer's metadata; nil only if the payload
    /// somehow cannot be encoded. Keys are sorted so re-encoding an unchanged
    /// description produces identical bytes.
    func json() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Strict, non-throwing decode: malformed JSON, a missing or unknown
    /// `type`, an unsupported `version`, an empty path, a non-positive
    /// duration or size, or a non-finite time all mean "this is a plain
    /// raster layer", never an error and never a crash.
    static func decode(_ json: String) -> LivePhotoPayload? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LivePhotoPayload.self, from: data),
              payload.type == typeName,
              payload.version == currentVersion,
              !payload.video.isEmpty,
              payload.duration.isFinite, payload.duration > 0,
              payload.time.isFinite, payload.time >= 0,
              payload.keyTime.isFinite, payload.keyTime >= 0,
              payload.width > 0, payload.height > 0,
              payload.width * payload.height <= RasterImage.maxResizePixels
        else { return nil }
        return payload
    }
}

/// A decoded Live Photo frame: a STRAIGHT-alpha RGBA8 raster (row 0 = top,
/// exactly `width * height * 4` bytes) at the payload's reference size.
struct LivePhotoRaster {
    let pixels: [UInt8]
    let width: Int
    let height: Int
}

/// Reading Live Photos: pairing the files, decoding frames, and naming the
/// layer — the one entry point the open path, the frame picker and the agent
/// all use, so a layer made any of those ways shows the same pixels.
///
/// Frames come from AVFoundation and stills from ImageIO because the Rust
/// core decodes neither HEIC nor video; this is the same seam text layers
/// already sit on, where the PLATFORM rasterizes and the core only stores
/// what came out. AVFoundation's synchronous asset API is deprecated in
/// macOS 13 in favour of async/await accessors, which this app deliberately
/// does not use (see app/CLAUDE.md) — the deprecation warnings from
/// `duration` and `tracks(withMediaType:)` are that trade, and nothing else
/// here relies on a deprecated call.
enum LivePhoto {
    /// How close to the key moment still counts AS the key moment: under one
    /// frame at 30 fps, so the snap can never swallow a neighbouring frame.
    static let keySnapTolerance = 0.02

    /// The timed-metadata identifier Apple marks the still's moment with.
    private static let stillImageTimeKey = "com.apple.quicktime.still-image-time"

    /// Longest layer name derived from a file name before it is elided.
    static let maxNameLength = 24

    /// File extensions each half of a pair may carry, lowercased. The still
    /// list is deliberately only what Photos writes (HEIC, or JPEG in "most
    /// compatible" mode): pairing is by name, so admitting every image format
    /// would turn an unrelated `shot.png`/`shot.mov` pair into a Live Photo.
    static let videoExtensions = ["mov", "m4v"]
    static let stillExtensions = ["heic", "heif", "jpg", "jpeg"]

    // MARK: - Finding the pair

    /// The Live Photo `url` belongs to, given either half of it: a movie
    /// (with its still if one sits beside it) or a still that HAS a movie
    /// beside it. nil for an ordinary image — a still with no clip is just a
    /// photo, and that is what makes this safe to try on every file the app
    /// opens.
    static func locate(_ url: URL) -> LivePhotoSource? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return LivePhotoSource(video: url, still: sibling(of: url, extensions: stillExtensions))
        }
        guard stillExtensions.contains(ext),
              let video = sibling(of: url, extensions: videoExtensions)
        else { return nil }
        return LivePhotoSource(video: video, still: url)
    }

    /// Same folder, same basename, one of `extensions` — the pairing Photos'
    /// own exports use. Both spellings are probed because the camera writes
    /// upper-case extensions and exporters often lower-case them; the pairing
    /// is by NAME only, so two unrelated files that share a basename do pair.
    private static func sibling(of url: URL, extensions: [String]) -> URL? {
        let base = url.deletingPathExtension()
        for ext in extensions {
            for candidate in [
                base.appendingPathExtension(ext), base.appendingPathExtension(ext.uppercased()),
            ] where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Reading the source

    /// Reads `source` and returns the payload a NEW layer starts from: the
    /// key moment displayed, the still's size (or the clip's when there is no
    /// still) as the reference size. nil when the clip cannot be read at all,
    /// which is what makes the caller fall back to opening the file as an
    /// ordinary image.
    static func inspect(_ source: LivePhotoSource) -> LivePhotoPayload? {
        guard FileManager.default.fileExists(atPath: source.video.path) else { return nil }
        let asset = AVURLAsset(url: source.video)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let keyTime = min(max(stillImageTime(asset) ?? 0, 0), duration)

        // The still is the layer's reference size when there is one: it is
        // the full-resolution photo, and the clip's frames are scaled up to
        // it. With no still, the clip's own frames set the size.
        var size = source.still.flatMap { Bitmap.imageSize($0) }
        if size == nil {
            size = videoFrame(source.video, at: keyTime, maxSide: 0)
                .map { CGSize(width: $0.width, height: $0.height) }
        }
        guard let size = size else { return nil }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0, width * height <= RasterImage.maxResizePixels else {
            return nil
        }
        return LivePhotoPayload(
            video: source.video, still: source.still, time: keyTime, keyTime: keyTime,
            duration: duration, width: width, height: height)
    }

    /// The moment the still was taken, from the clip's timed-metadata track:
    /// Apple writes one `still-image-time` sample there and its presentation
    /// time IS the moment. nil when the clip has no such track (an ordinary
    /// movie, or one re-encoded by a tool that dropped it), and the caller
    /// then treats the start of the clip as the key moment.
    private static func stillImageTime(_ asset: AVAsset) -> Double? {
        for track in asset.tracks(withMediaType: .metadata) {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            // The adaptor must exist BEFORE reading starts: attaching one to
            // an output that has already moved past AVAssetReaderStatusUnknown
            // raises an Objective-C exception, which Swift cannot catch.
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            defer { reader.cancelReading() }
            while let group = adaptor.nextTimedMetadataGroup() {
                let marksTheStill = group.items.contains { item in
                    (item.identifier?.rawValue ?? "").hasSuffix(stillImageTimeKey)
                }
                guard marksTheStill else { continue }
                let start = group.timeRange.start.seconds
                return start.isFinite ? start : nil
            }
        }
        return nil
    }

    // MARK: - Decoding frames

    /// The frame `payload` describes, as a CGImage bounded by `maxSide`
    /// (0 = the source's own size): the full-resolution still at the key
    /// moment, a decoded video frame anywhere else. nil once the files are
    /// gone.
    static func frameImage(_ payload: LivePhotoPayload, maxSide: Int = 0) -> CGImage? {
        if payload.showsStill, let still = payload.stillURL,
           let image = Bitmap.decodeImage(still, maxSide: maxSide) {
            return image
        }
        // A still that will not decode (or was never there) still has the
        // clip behind it, so fall through rather than fail.
        return videoFrame(payload.videoURL, at: payload.time, maxSide: maxSide)
    }

    /// One exact frame of a clip. The generator's DEFAULT time tolerance is
    /// infinite, which snaps every request to the nearest sync frame and
    /// would make the timeline lie about what it is showing; zero tolerance
    /// on both sides is what makes scrubbing WYSIWYG.
    private static func videoFrame(_ url: URL, at time: Double, maxSide: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if maxSide > 0 {
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        }
        let requested = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        return try? generator.copyCGImage(at: requested, actualTime: nil)
    }

    /// The layer pixels for `payload`, at its reference size — video frames
    /// are scaled up to the still's size, so every frame of a layer has the
    /// same geometry. nil once the source files are gone.
    static func render(_ payload: LivePhotoPayload) -> LivePhotoRaster? {
        guard let image = frameImage(payload),
              let pixels = Bitmap.straightRGBA(
                from: image, fitting: payload.width, height: payload.height)
        else { return nil }
        return LivePhotoRaster(pixels: pixels, width: payload.width, height: payload.height)
    }

    // MARK: - Naming and prompts

    /// The layer name a Live Photo gets: the file's basename, elided.
    static func layerName(for source: LivePhotoSource) -> String {
        let base = (source.still ?? source.video).deletingPathExtension().lastPathComponent
        guard !base.isEmpty else { return "Live Photo" }
        guard base.count > maxNameLength else { return base }
        return String(base.prefix(maxNameLength)) + "…"
    }

    /// A one-line summary of what a payload is showing, for the frame
    /// picker's readout and the status line: "1.42 s of 2.97 s" plus, at the
    /// key moment, that this is the photo itself.
    static func frameDescription(_ payload: LivePhotoPayload) -> String {
        let position = String(format: "%.2f s of %.2f s", payload.time, payload.duration)
        return payload.showsStill ? "\(position) · key frame (the photo)" : position
    }

    /// Asks whether a destructive edit may cut a layer loose from its Live
    /// Photo. App-modal (not a sheet) for the same reason the text prompt is:
    /// the edits that ask — a filter, a fill click, a finished brush stroke —
    /// are synchronous and must have the answer before touching the document.
    static func confirmRasterize(layerName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rasterize Live Photo layer?"
        alert.informativeText =
            "This edit paints over “\(layerName)”, so the layer will no longer be linked to "
            + "its Live Photo: you will not be able to choose a different frame. The pixels "
            + "themselves are kept."
        alert.addButton(withTitle: "Rasterize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Reading and building live photo layers on a document

extension RasterDocument {
    /// Layer `idx`'s Live Photo description, or nil when it has none (a plain
    /// raster layer, a text layer, or metadata this app does not recognize).
    func livePhotoPayload(_ idx: Int) -> LivePhotoPayload? {
        guard let meta = layerMeta(idx) else { return nil }
        return LivePhotoPayload.decode(meta)
    }

    /// Attaches `payload` to layer `idx` as its metadata (pure, like every
    /// other layer op — the pixels are the caller's to chain).
    func withLivePhotoPayload(_ idx: Int, _ payload: LivePhotoPayload) -> RasterDocument? {
        guard let json = payload.json() else { return nil }
        return withLayerMeta(idx, json)
    }

    /// A single-layer document showing `payload`'s frame — the open path for
    /// a Live Photo, where the canvas takes the photo's own size.
    static func from(livePhoto payload: LivePhotoPayload, name: String) -> RasterDocument? {
        guard let raster = LivePhoto.render(payload),
              let image = RasterImage.from(
                rgba: raster.pixels, width: raster.width, height: raster.height),
              let doc = RasterDocument.from(image: image),
              let named = doc.withLayerName(0, name)
        else { return nil }
        return named.withLivePhotoPayload(0, payload)
    }

    /// Inserts `payload`'s frame as a new layer above `idx` (at offset 0,0,
    /// like every other added layer) carrying its description, in one handle
    /// so the whole insertion is one undo step.
    func addingLivePhotoLayer(
        above idx: Int, _ payload: LivePhotoPayload, name: String
    ) -> RasterDocument? {
        guard let raster = LivePhoto.render(payload),
              let image = RasterImage.from(
                rgba: raster.pixels, width: raster.width, height: raster.height),
              let added = addingImageLayer(above: idx, image, name: name)
        else { return nil }
        return added.withLivePhotoPayload(idx + 1, payload)
    }

    /// Re-renders live photo layer `idx` at `seconds` and records the new
    /// moment, as one handle. nil — never an identical copy — when the layer
    /// carries no Live Photo description, when the requested moment is the
    /// one already showing (after clamping and key-snapping, so a phantom
    /// undo step is impossible), or when the source files are gone.
    ///
    /// The frame always arrives at the payload's reference size, so a layer
    /// that still has that size keeps its mask; one that was transformed or
    /// cropped since snaps back to the full frame, and the core drops the
    /// mask a resize invalidates.
    func settingLivePhotoFrame(_ idx: Int, seconds: Double) -> RasterDocument? {
        guard let payload = livePhotoPayload(idx) else { return nil }
        let updated = payload.settingTime(seconds)
        guard updated != payload, let raster = LivePhoto.render(updated) else { return nil }
        return withLayerPixels(
            idx, rgba: raster.pixels, width: raster.width, height: raster.height)?
            .withLivePhotoPayload(idx, updated)
    }
}
