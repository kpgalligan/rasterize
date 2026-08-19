import AppKit
import UniformTypeIdentifiers

/// Live Photo commands: placing one as a layer, and picking which of its
/// frames that layer shows. The frame picker itself is
/// LivePhotoFrameSheetController; the model is LivePhotoLayer.swift.
extension EditorViewController {
    /// Layer > Select Live Photo Frame… — the active layer's timeline. The
    /// layers panel's row menu and row double-click go to
    /// `editLivePhotoLayer` directly, so they act on the row under the
    /// cursor.
    @objc func selectLivePhotoFrame(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        editLivePhotoLayer(document.activeLayerIndex)
    }

    /// Opens layer `idx`'s frame picker, having made it the active layer —
    /// re-opening a layer's source selects it, exactly as the text and
    /// adjustment paths do.
    func editLivePhotoLayer(_ idx: Int) {
        guard let document = document, let doc = document.doc,
              let payload = doc.livePhotoPayload(idx)
        else {
            NSSound.beep()
            return
        }
        setActiveLayer(idx)
        // The clip is referenced, not copied into the document, so it can be
        // gone by the time someone asks for another frame. Say so instead of
        // opening a picker that could not render anything.
        guard payload.sourceExists else {
            let alert = NSAlert()
            alert.messageText = "The Live Photo's video is missing."
            alert.informativeText =
                "Rasterize reads the frames from “\(payload.videoURL.path)”, which is no "
                + "longer there. The layer's pixels are unaffected, but another frame cannot "
                + "be rendered until the file is back."
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        presentAsSheet(
            LivePhotoFrameSheetController(
                document: document, canvas: canvas, layer: idx, payload: payload))
    }

    /// Layer > Place Live Photo… — picks a Live Photo (either half of the
    /// pair, or a bare clip) and adds its key frame as a new layer above the
    /// active one, carrying the description the frame picker re-renders from.
    @objc func placeLivePhoto(_ sender: Any?) {
        guard let document = document, document.doc != nil, let window = view.window else {
            NSSound.beep()
            return
        }
        // Never leave a canvas session hanging behind a modal panel.
        commitPendingSessions()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Live Photo — its photo or its video."
        panel.prompt = "Place"
        panel.allowedContentTypes = Self.livePhotoContentTypes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.placeLivePhoto(from: url)
        }
    }

    /// The file types the Place panel offers: both halves of a pair, since
    /// either one identifies the Live Photo.
    private static let livePhotoContentTypes: [UTType] = {
        let names = LivePhoto.stillExtensions + LivePhoto.videoExtensions
        return names.compactMap { UTType(filenameExtension: $0) }
    }()

    /// The picked file, as a new layer. Refuses a file that is not half of a
    /// Live Photo — a lone photo would just be an image, and this command
    /// promises a layer whose frame can be changed later.
    private func placeLivePhoto(from url: URL) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        guard let source = LivePhoto.locate(url), let payload = LivePhoto.inspect(source) else {
            let alert = NSAlert()
            alert.messageText = "That is not a Live Photo."
            alert.informativeText =
                "A Live Photo is a photo and a short video sharing one name in one folder "
                + "(IMG_0001.HEIC and IMG_0001.MOV). Open a plain image with File > Open "
                + "instead."
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        let below = document.activeLayerIndex
        let before = doc
        document.applyEdit("Place Live Photo") {
            $0.addingLivePhotoLayer(above: below, payload, name: LivePhoto.layerName(for: source))
        }
        guard document.doc !== before, let updated = document.doc else { return }
        setActiveLayer(min(below + 1, updated.layerCount - 1))
    }
}
