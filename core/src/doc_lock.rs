//! Layer LOCKS: the four bits `Layer::locks` carries, what each one forbids,
//! and [`RzDocument::lock_block`] — the query a host asks to phrase a refusal
//! that names the lock that stopped an edit. The ops themselves refuse
//! regardless, so a host that forgets to ask cannot get through.
//!
//! # The bits
//!
//! ```text
//! bit 0  LOCK_TRANSPARENCY = 1   the alpha channel is frozen
//! bit 1  LOCK_PIXELS       = 2   no pixel edit at all
//! bit 2  LOCK_POSITION     = 4   no move, no transform, no offset change
//!        LOCK_ALL          = 7   all three — "Lock All" is spelled the way
//!                                PSD's `lspf` spells it, not as a 4th bit
//! ```
//!
//! Bits 3..31 are reserved and are masked off wherever a value enters (the
//! setter, the `.rz` reader, the FFI), so a file from a newer build loads with
//! the locks this one understands rather than being refused.
//!
//! # What each lock means
//!
//! **Transparency** freezes the layer's ALPHA CHANNEL: every pixel op's result
//! has the layer's original alpha restored. That is Photoshop's actual
//! behaviour and it is stronger and simpler than "multiply stroke coverage by
//! the existing alpha" — at alpha 128 a stroke takes the new colour fully and
//! keeps its softness instead of the paint being halved, and an eraser cannot
//! punch a hole. Two kinds of pixel get their COLOUR back with their alpha:
//! one the layer already holds at zero alpha (nothing there is visible, so
//! those bytes are not part of the picture) and one the OP drove to zero (an
//! erase or a clear, which zero the colour as they go — restoring only the
//! alpha would resurrect the pixel in black). Both together are what make an
//! edit that only tried to remove coverage a byte-exact no-op, which is what
//! the purity latch needs to see so it can return `None` instead of minting an
//! undo step.
//!
//! **Pixels** refuses every pixel edit. Mask edits are NOT blocked by it:
//! Photoshop lets you paint a pixel-locked layer's mask, and so does this.
//!
//! **Position** refuses `with_layer_offset`, `move_layers`, `transform_layers`
//! and `perspective_layer`. Moving a GROUP checks the group's own position bit
//! AND every descendant's, because moving a group moves them.
//!
//! **A transform is a POSITION edit only, never a Pixels edit.** A transform
//! resamples the whole buffer INCLUDING its alpha, so "the alpha channel is
//! frozen" has no meaning there: transparency lock gates painting INTO an
//! existing buffer, and position lock is the flag that refuses a transform.
//! Were a transform "Pixels + Position", a layer with ONLY transparency locked
//! would become untransformable, because a transform derives its own extent
//! and so almost always changes the layer's size and offset — a regression
//! against the very reference the frozen-alpha rule cites, since Photoshop's
//! Lock Transparency does not block Free Transform and Lock Position does.
//!
//! **All three set** additionally freezes the MASK (`add_mask`,
//! `remove_mask`, `paint_mask`, `set_mask_enabled` refuse). That is the one
//! extra meaning "Lock All" carries beyond the union of the three.
//!
//! **APPLYING a mask is the one mask operation TRANSPARENCY also refuses**
//! ([`EditKind::MaskApply`], which `remove_mask(idx, apply: true)` runs
//! under). Adding, painting, enabling and deleting a mask leave the layer's
//! alpha alone, which is why Lock Pixels does not gate them; APPLYING one
//! multiplies the mask straight into that alpha, so it is exactly the edit
//! "the alpha channel is frozen" promises cannot happen — a hide-all mask
//! applied to a transparency-locked layer would otherwise erase the whole
//! layer, which is the hole an eraser is not allowed to punch. Blocking it in
//! `lock_block` rather than restoring the alpha afterwards is what lets the
//! host NAME the lock: an apply that silently came back unchanged would look
//! like a failure with no reason.
//!
//! **A MERGE answers to the DESTINATION entry's locks**
//! ([`EditKind::Merge`], which `merging_down` and `merge_layers` ask about the
//! lower operand). Pixels refuses it because a merge replaces that entry's
//! whole picture — the one op that destroys a layer's contents outright.
//! Transparency refuses it for the reason [`RzDocument::freezing_alpha`]
//! refuses any resized Pixels edit: a merge derives a new extent from the
//! union of both operands, and a frozen alpha channel cannot follow a buffer
//! that moved. The UPPER operand is only REMOVED, and removal is never
//! blocked, so its locks do not count.
//!
//! Locks never block delete, duplicate, reorder, group/ungroup, rename,
//! opacity, blend mode, visibility or style. Photoshop does not block those
//! either, and blocking them would make a locked layer unmanageable.
//!
//! # The ONE enforcement point
//!
//! Every op that writes a layer wraps its body in [`RzDocument::under_locks`]
//! (or [`RzDocument::under_locks_fallible`], for the healing family, which
//! reports through `Result`). There is no second place a lock is consulted, so
//! a new pixel op is either wrapped or it is a bug `structure_tests`' lock
//! sweep catches.
//!
//! The two MERGES are the exception the wrapper cannot express, and they are
//! not an exemption: `merging_down` and `merge_layers` drain their operands'
//! subtrees, so the entry the lock belongs to does not survive the edit at the
//! index it was asked about and `under_locks`' after-the-fact alpha restore
//! has nothing to write to. Both therefore ask [`RzDocument::lock_block`]
//! directly, with [`EditKind::Merge`], BEFORE touching anything — the same
//! question, asked at the only point in those ops where the answer still
//! addresses a live entry. The lock sweep covers them like any other writer.
//!
//! ONE site is deliberately NOT wrapped, and this is the note that keeps
//! someone from "fixing" it: `doc_heal::heal_window_into_layer`. It is a
//! module-level free function taking `doc: &RzDocument` rather than an
//! `impl RzDocument` method, so `self.under_locks(...)` cannot wrap it; and
//! its only caller hands it an internal ONE-LAYER TEMP document built for the
//! reduced-resolution preview, whose layer carries no locks — and if it ever
//! inherited them, the preview would refuse itself. The locks are enforced one
//! level up, at `heal_layer` / `spot_heal_layer` / `content_aware_fill`, which
//! is where the caller's real layer index enters.

use std::sync::Arc;

use crate::doc::{Layer, LayerKind, RzDocument};
use crate::doc_group::subtree;

/// The layer's alpha channel is frozen; colour may change, coverage may not.
pub const LOCK_TRANSPARENCY: u32 = 1;
/// No pixel edit at all.
pub const LOCK_PIXELS: u32 = 2;
/// No move, no transform, no offset change.
pub const LOCK_POSITION: u32 = 4;
/// All three — "Lock All", and the mask frozen with them.
pub const LOCK_ALL: u32 = LOCK_TRANSPARENCY | LOCK_PIXELS | LOCK_POSITION;

/// What kind of edit is being attempted, for [`RzDocument::lock_block`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(i32)]
pub enum EditKind {
    /// Anything that writes the layer's pixels.
    Pixels = 0,
    /// Anything that moves or resamples it: offset, move, transform,
    /// perspective.
    Position = 1,
    /// Anything that adds, removes, enables or paints its mask.
    Mask = 2,
    /// APPLYING a mask: a mask operation that also bakes the coverage into
    /// the layer's ALPHA. Blocked by Lock Transparency as well as by Lock
    /// All — see the module doc.
    MaskApply = 3,
    /// A MERGE writing this entry: its whole buffer is replaced, at a new
    /// extent derived from both operands. Blocked by Lock Pixels and by Lock
    /// Transparency — see the module doc.
    Merge = 4,
}

impl EditKind {
    /// Maps a raw `RzEditKind` value coming across the FFI.
    pub fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(EditKind::Pixels),
            1 => Some(EditKind::Position),
            2 => Some(EditKind::Mask),
            3 => Some(EditKind::MaskApply),
            4 => Some(EditKind::Merge),
            _ => None,
        }
    }
}

impl RzDocument {
    /// Which of entry `idx`'s lock bits would block an edit of `kind`
    /// (0 = allowed). The host asks this to phrase a refusal that names the
    /// lock; the ops themselves refuse regardless, so a host that forgets
    /// cannot get through. 0 for an out-of-range index — there is no entry to
    /// be locked, and the op refuses on the index alone.
    ///
    /// A POSITION edit on a group also answers with its descendants' position
    /// bits, because moving a group moves them; a MASK edit is blocked only by
    /// Lock All, which is the one extra meaning that spelling carries; and a
    /// MASK APPLY — the one mask op that writes the layer's alpha — is blocked
    /// by Lock Transparency too, as is a MERGE that would replace this entry's
    /// picture.
    pub fn lock_block(&self, idx: usize, kind: EditKind) -> u32 {
        let Some(entry) = self.layers.get(idx) else {
            return 0;
        };
        let locks = entry.locks & LOCK_ALL;
        match kind {
            EditKind::Pixels => locks & LOCK_PIXELS,
            EditKind::Position => {
                let mut blocked = locks & LOCK_POSITION;
                if entry.kind == LayerKind::Group {
                    for i in subtree(&self.layers, idx) {
                        blocked |= self.layers[i].locks & LOCK_POSITION;
                    }
                }
                blocked
            }
            EditKind::Mask => {
                if locks == LOCK_ALL {
                    LOCK_ALL
                } else {
                    0
                }
            }
            EditKind::MaskApply => {
                if locks == LOCK_ALL {
                    LOCK_ALL
                } else {
                    locks & LOCK_TRANSPARENCY
                }
            }
            EditKind::Merge => locks & (LOCK_PIXELS | LOCK_TRANSPARENCY),
        }
    }

    /// Pure setter: replaces entry `idx`'s lock flags, masking off the
    /// reserved bits so a caller cannot store a value this build would not
    /// understand. `None` on an out-of-range index, and `None` when the entry
    /// already carries exactly those flags — the core's purity rule, which is
    /// load-bearing here: the host registers an undo step and dirties the
    /// document for every non-nil answer, so an identical copy would put a
    /// phantom step between the user and their last real edit.
    pub fn with_layer_locks(&self, idx: usize, locks: u32) -> Option<Self> {
        let locks = locks & LOCK_ALL;
        if self.layers.get(idx)?.locks == locks {
            return None;
        }
        let mut doc = self.clone();
        doc.layers[idx].locks = locks;
        Some(doc)
    }

    /// Runs `op` under entry `idx`'s locks — the ONE place locks are enforced.
    /// Refuses (`None`) when a lock forbids the edit outright, and restores
    /// the layer's original alpha afterwards when transparency is locked.
    ///
    /// Refuses too when a transparency-locked edit changed the layer's SIZE or
    /// OFFSET, since a frozen alpha channel cannot follow a buffer that moved
    /// — which is exactly why a transform is a Position edit and not a Pixels
    /// one (see the module doc).
    ///
    /// AFTER the alpha restore it compares the resulting layer's pixels and
    /// mask against the input's and returns `None` when nothing moved. The
    /// core's purity rule is that an op which changes nothing returns `None`,
    /// never an identical copy, and the alpha restore is precisely what CAN
    /// mint one: `clear_selection`, an eraser stroke, or a brush stroke that
    /// lands entirely where alpha is 0 all come back byte-identical on a
    /// transparency-locked layer — and all three are MCP-reachable, so each
    /// would otherwise add an undo step and dirty the document for nothing.
    /// This is the same latch `painting_layer` already applies for an
    /// out-of-extent overlay.
    pub(crate) fn under_locks(
        &self,
        idx: usize,
        kind: EditKind,
        op: impl FnOnce(&Self) -> Option<Self>,
    ) -> Option<Self> {
        if self.lock_block(idx, kind) != 0 {
            return None;
        }
        self.freezing_alpha(idx, kind, op(self)?)
    }

    /// The `Result`-returning mirror of [`Self::under_locks`], for the healing
    /// and inpainting ops, whose bodies report I/O-shaped failures through
    /// `Err`. A lock refusal is a DOMAIN refusal, so it comes back as
    /// `Ok(None)` — the same shape those ops already use for "nothing to do" —
    /// and never as an error string the host would show as a failure.
    pub(crate) fn under_locks_fallible(
        &self,
        idx: usize,
        kind: EditKind,
        op: impl FnOnce(&Self) -> Result<Option<Self>, String>,
    ) -> Result<Option<Self>, String> {
        if self.lock_block(idx, kind) != 0 {
            return Ok(None);
        }
        let Some(out) = op(self)? else {
            return Ok(None);
        };
        Ok(self.freezing_alpha(idx, kind, out))
    }

    /// The transparency half of [`Self::under_locks`]: `out` with entry
    /// `idx`'s original alpha channel restored, or `None` when the edit could
    /// not be reconciled with a frozen alpha (a resized or moved buffer) or
    /// when the restore left the layer byte-identical.
    ///
    /// A no-op for any entry that is not transparency-locked and for every
    /// edit kind but `Pixels`: a Position edit resamples the alpha with
    /// everything else, a Mask edit never touches the layer's alpha at all,
    /// and a Mask APPLY and a Merge — the two that do — are refused outright by
    /// [`RzDocument::lock_block`] rather than silently un-applied.
    fn freezing_alpha(&self, idx: usize, kind: EditKind, out: Self) -> Option<Self> {
        let before = self.layers.get(idx)?;
        if kind != EditKind::Pixels || before.locks & LOCK_TRANSPARENCY == 0 {
            return Some(out);
        }
        let after = out.layers.get(idx)?;
        if after.pixels.dimensions() != before.pixels.dimensions() || after.offset != before.offset
        {
            return None;
        }
        let mut restored = (*after.pixels).clone();
        let raw: &mut [u8] = &mut restored;
        for (dst, src) in raw
            .chunks_exact_mut(4)
            .zip(before.pixels.as_raw().chunks_exact(4))
        {
            if src[3] == 0 || dst[3] == 0 {
                // Two pixels get their COLOUR back as well as their alpha.
                //
                // `src[3] == 0`: the layer holds nothing there, so the colour
                // bytes under it are not part of the picture. Putting them
                // back is what makes a stroke that landed only in the empty
                // area a byte-exact no-op the latch below can see; otherwise
                // it would come back "changed" in bytes nobody can look at,
                // and mint an undo step for nothing.
                //
                // `dst[3] == 0`: the op drove the alpha to zero — an erase, or
                // `clear_selection`, both of which zero the colour with it.
                // Restoring only the alpha would resurrect the pixel in
                // whatever colour the erase left behind (black), so an edit
                // that tried to REMOVE coverage is refused outright instead.
                dst.copy_from_slice(src);
            } else {
                dst[3] = src[3];
            }
        }
        let unchanged = restored.as_raw() == before.pixels.as_raw() && same_mask(after, before);
        if unchanged {
            return None;
        }
        let mut doc = out;
        doc.layers[idx].pixels = Arc::new(restored);
        Some(doc)
    }
}

/// Whether two entries carry the same mask bytes and the same enabled flag —
/// the other half of [`RzDocument::freezing_alpha`]'s no-op latch, so an edit
/// that touched only the mask is not thrown away with the pixels.
fn same_mask(a: &Layer, b: &Layer) -> bool {
    a.mask_enabled == b.mask_enabled
        && match (a.mask.as_deref(), b.mask.as_deref()) {
            (None, None) => true,
            (Some(x), Some(y)) => x.dimensions() == y.dimensions() && x.as_raw() == y.as_raw(),
            _ => false,
        }
}
