# Validation — 27 October 2026

## Automated

`swift test`: 18 tests, 0 failures. They cover PDF reading (paths, colors, dashes, curves, text outlines, coordinate flip), reporting of raster content, rejection of invalid and multi-page PDFs, EMF record structure, static-only SVG output, the Office package (valid zip, relationship type, size in EMU, XML escaping, CRC-32), ChemDraw type recognition, ignoring non-ChemDraw copies, keeping every original representation, not adding generic image types, not overwriting a newer copy, picture mode at 600 dpi, the bitmap fallback for incomplete vectors, and the round trip: CDX embedded in and recovered from the SVG, from stored and deflate-compressed Office packages, restored to the clipboard without bitmap types, only for ChemDraw types, and never for ordinary Office copies.

## Real ChemDraw clipboards

Two ChemDraw clipboard PDFs (a 358 × 93 pt structure, and a 391 × 222 pt two-panel reaction scheme with colored labels, subscripts, charges, radicals, curved arrows, dashed boxes and two embedded fonts, TrueType and CFF) converted completely. The resulting EMF and SVG were decoded independently and rendered; they matched the PDF. Conversion of the scheme in the running app took under a second.

## In Office and ChemDraw (manual, this Mac)

| Check | Result |
|---|---|
| ⌘V in PowerPoint, Vector mode | Pasted as a Graphic; SVG stored byte-for-byte in the saved .pptx |
| Save as Picture → SVG, Vector mode | Sharp |
| Save as Picture → PNG, Vector mode | Low resolution (Office's export of SVG graphics) |
| ⌘V in PowerPoint, Picture mode; Save as Picture → PNG | Sharp |
| ⌘V back into ChemDraw | Editable structure |
| ChemDraw → PowerPoint, copy other text, copy the picture in PowerPoint → ChemDraw | Editable structure |
| Word, Excel, Outlook | Not yet confirmed |
| Saved .pptx opened in PowerPoint (Microsoft 365) on a Windows PC | Sharp, shown as a Graphic. The file holds ChemClip's SVG (with the embedded structure) plus PowerPoint's own fallback PNG (384 dpi) |
| ChemDraw on the Mac → paste into PowerPoint for the web in a Windows VM's browser | Blurry bitmap: browsers and the Parallels shared clipboard carry only text and bitmaps, so ChemClip's picture never reaches the web app |
| Copying from a deck closed and reopened → ChemDraw | Editable structure |

## Package (1.0.0)

Universal app (arm64 + x86_64), ad hoc signed with hardened runtime; `codesign --verify --deep --strict` passes. The DMG contains the app, an Applications link and install notes. Not notarized: first launch needs Control-click → Open.
