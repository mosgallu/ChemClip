# Clipboard and Office findings

Investigated 27 October 2026 on macOS 26.3 (Apple silicon), ChemDraw 26.1.0.6801 and PowerPoint 16.88.1.

## The cause

ChemDraw for Mac's clipboard holds one item with `com.adobe.pdf`, `com.revvity.chemdraw.cdx-clipboard`, `com.mdli.sketchfile`, `com.mdli.molfile` and `org.opensmiles.smiles`. There is no EMF or SVG. The PDF is produced by macOS's Quartz PDFContext: filled and stroked paths, solid colors, and text in subset TrueType or CFF fonts embedded in the PDF. ChemDraw also embeds its CDXML in the PDF's metadata stream.

When this is pasted normally, PowerPoint stores the picture as an EMF containing an EMF+ bitmap and a private `GDIC` comment. For one test structure the bitmap was 56 × 176 px. Office for Mac draws the private data, so the picture looks sharp on the Mac, but Windows Office and Save as Picture use the bitmap. Office's own "Paste as Picture" produces the same kind of EMF with a larger bitmap (~1,500 px wide), which is still a bitmap on Windows.

Community reports agree: [Microsoft Q&A: Mac PPT images blurry on Windows](https://learn.microsoft.com/en-us/answers/questions/5408720/why-do-images-in-ppt-for-mac-come-through-blurry-i), [Microsoft Q&A: pixelated on Windows](https://learn.microsoft.com/en-us/answers/questions/5679897/i-did-my-powerpoint-presentation-in-mac-when-opene), [Revvity: low-resolution paste](https://support.revvitysignals.com/hc/en-us/articles/4408239935508-ChemDraw-When-I-paste-structures-into-Microsoft-Word-or-other-applications-the-result-is-a-poor-looking-low-resolution-image), [Revvity: Mac/PC sharing](https://support.revvitysignals.com/hc/en-us/articles/4408239584916-ChemDraw-Unable-to-share-Microsoft-Office-files-containing-embedded-ChemDraw-16-structures-between-Mac-and-PC-Operating-Systems).

## Office's clipboard format

Copying a picture in PowerPoint for Mac puts `com.microsoft.Art--GVML-ClipFormat` on the pasteboard: a zip with `[Content_Types].xml`, `_rels/.rels` (relationship type `…/relationships/drawing`), `clipboard/drawings/drawing1.xml` (a DrawingML `lockedCanvas` holding one `a:pic`), its `.rels`, the media, and an optional theme. A package whose root relationship used `…/officeDocument` was silently ignored. The theme is not needed. Other descriptions of the format: [ykuwai/ppt-mcp#211](https://github.com/ykuwai/ppt-mcp/issues/211), [kfchem/Meno#69](https://github.com/kfchem/Meno/pull/69).

PowerPoint reads this format in preference to the PDF on the same item.

## What was tried

| Office picture in the package | Result in PowerPoint for Mac |
|---|---|
| Plain GDI EMF (vector) | Stored byte-for-byte, but drawn at low resolution on the Mac |
| SVG via `asvg:svgBlip`, EMF fallback | Stored byte-for-byte as SVG; **Graphics Format** tab; sharp; Save as Picture → SVG is sharp. PowerPoint replaced the fallback with its own 384 dpi PNG |
| 600 dpi PNG | Sharp; Save as Picture → PNG keeps the resolution |

Save as Picture → PNG of an SVG graphic is rendered by Office at low resolution; that is Office's export behavior, not the stored picture. Hence the two modes.

Adding `public.png` to the clipboard made ChemDraw paste a non-editable picture instead of its CDX data. Without it, ChemDraw pastes an editable structure from the rewritten clipboard. ([pptCDXbridge](https://github.com/mmaskeri/pptCDXbridge) addresses a related case by putting CDX back on the clipboard.)

Because PowerPoint keeps the SVG unchanged, ChemClip embeds ChemDraw's CDX in the SVG as an XML comment. A first version used a `<metadata>` element with a custom namespace; PowerPoint then drew the picture noticeably less sharply, consistent with rejecting the SVG and using the EMF fallback. With a comment the SVG is drawn sharply again. Copying the picture in PowerPoint puts the SVG back on the clipboard inside Office's package; ChemClip recognizes its metadata and adds the CDX under ChemDraw's clipboard type, which ChemDraw pastes as an editable structure (verified).

Microsoft documents SVG support in Microsoft 365 for Windows and Mac ([Edit SVG images in Microsoft 365](https://support.microsoft.com/en-gb/office/graphics-visuals/edit-svg-images-in-microsoft-365)). A deck saved on the Mac opened sharply in PowerPoint (Microsoft 365) on a Windows PC. Apps that cannot draw SVG use the fallback PNG that PowerPoint for Mac generates (384 dpi in the test). Pasting through a web browser or a virtual machine's shared clipboard bypasses ChemClip entirely: only text and bitmaps cross that boundary.
