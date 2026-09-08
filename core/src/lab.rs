//! The CIE L*a*b* readout: one straight RGB triple of a DOCUMENT's pixels,
//! through that document's own profile, against the D50 PCS white.
//!
//! # Which white, and why nothing is adapted here
//!
//! **D50.** Photoshop's Lab is defined on the ICC PCS white, which is D50,
//! and the Info panel's readout is that Lab. More usefully for this
//! codebase, the correct pipeline falls out of what the colour-management
//! work already built and costs nothing extra: a matrix/TRC profile's
//! `rXYZ`/`gXYZ`/`bXYZ` columns **are already D50-adapted** (the ICC spec
//! requires it; `icc_transform`'s module doc has the proof), so the readout
//! is simply
//!
//! ```text
//! encoded RGB -> the profile's own TRCs -> linear
//!             -> the profile's own to_pcs -> XYZ, already D50
//!             -> Lab against (0.96422, 1.0, 0.82521)
//! ```
//!
//! No extra adaptation and no sRGB assumption — which is the entire point:
//! the SAME bytes read differently in an sRGB and a Display P3 document, and
//! that difference is what tells a user their numbers are being honoured.
//! Worked values the tests pin: `(200, 150, 120)` is
//! `L 66.408, a 16.507, b 23.547` in an sRGB document and
//! `L 66.743, a 21.179, b 27.018` in a Display P3 one.
//!
//! A profile this build cannot model — the LUT-based profiles the core
//! deliberately keeps on a document rather than refusing — has no
//! matrix/TRC model, so [`RzDocument::lab`] returns `None` and the host says
//! so. A silent sRGB fallback would be exactly the bug the colour-management
//! work spent a page warning about.

use crate::doc::RzDocument;

/// The ICC PCS white as XYZ.
const D50: [f32; 3] = [0.96422, 1.00000, 0.82521];

/// CIE's `epsilon` and `kappa`, in their exact rational form.
const EPSILON: f32 = 216.0 / 24389.0;
const KAPPA: f32 = 24389.0 / 27.0;

/// The CIE L*a*b* companding function.
fn f(t: f32) -> f32 {
    if t > EPSILON {
        t.cbrt()
    } else {
        (KAPPA * t + 16.0) / 116.0
    }
}

/// XYZ (already D50-adapted) to L*a*b*.
fn xyz_to_lab(xyz: [f32; 3]) -> [f32; 3] {
    let fx = f(xyz[0] / D50[0]);
    let fy = f(xyz[1] / D50[1]);
    let fz = f(xyz[2] / D50[2]);
    [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
}

impl RzDocument {
    /// The CIE L*a*b* of one straight RGB triple of THIS document's pixels,
    /// read through the document's own profile against the D50 PCS white
    /// (module doc). `None` for a profile with no matrix/TRC model, where
    /// the host must say so rather than assume sRGB.
    pub fn lab(&self, rgb: [u8; 3]) -> Option<[f32; 3]> {
        let model = self.profile.model()?;
        let encoded = rgb.map(|v| f32::from(v) / 255.0);
        Some(xyz_to_lab(model.to_pcs_xyz(encoded)))
    }
}
