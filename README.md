# ChemClip

**Sharp ChemDraw drawings in Microsoft Office for Mac.**

Copy in ChemDraw with ⌘C and paste into Word, PowerPoint, Excel or Outlook with ⌘V. The drawing arrives as a vector graphic that stays sharp at any zoom, when the file is opened on Windows, and when you export it as SVG or PDF. Copy it from Office later and paste it into ChemDraw, and it is an editable structure again.

ChemClip is a small menu-bar app. It needs no other software and no special permissions, and it writes no files.

## Install

Requires macOS 13 or later, on Apple silicon or Intel.

1. Download `ChemClip.dmg` from the [latest release](https://github.com/mosgallu/ChemClip/releases/latest), or [build it yourself](#build-from-source).
2. Open `ChemClip.dmg` and drag **ChemClip** onto **Applications**, following the arrow.
3. Open **Applications**, Control-click **ChemClip** and choose **Open**, then click **Open** again. This is needed only the first time, because ChemClip is not notarized by Apple. If macOS still refuses, go to System Settings → Privacy & Security and click **Open Anyway** next to ChemClip.
4. A benzene-ring icon appears in the menu bar. Click it and choose **Open at Login** so ChemClip starts with your Mac.

ChemClip has no window; everything is in the menu-bar icon. You can eject and delete the disk image afterwards.

To uninstall, choose **Quit ChemClip** in its menu and move ChemClip from Applications to the Trash.

## Use

ChemClip works in the background while it runs. Keep using ⌘C and ⌘V as usual.

### ChemDraw → Office

1. In ChemDraw, select a structure, scheme or the whole drawing and press **⌘C**.
2. Within a moment the menu-bar status reads *Ready to paste into Office as a vector graphic*.
3. In Word, PowerPoint, Excel or Outlook, press **⌘V**. The picture is a vector Graphic: PowerPoint shows the **Graphics Format** tab when it is selected.

Resize it freely; it stays sharp on screen, in print, in PDFs and when the file is opened on Windows.

### Office → ChemDraw (editing again)

1. In Office, select a picture that was pasted with ChemClip and press **⌘C**.
2. The status reads *Ready to paste into ChemDraw as an editable structure*.
3. In ChemDraw, press **⌘V**. You get the original structure, with atoms and bonds you can edit, not a picture.

This also works in files that were saved, closed and reopened, or that someone sent you.

### Exporting pictures

| Need | In Office |
|---|---|
| A sharp vector file | Right-click the picture → Save as Picture → **SVG** or **PDF** |
| A sharp PNG | Switch the menu to **High-Resolution Picture (600 dpi)**, paste again, then Save as Picture → **PNG** |

Office exports SVG graphics to PNG at low resolution. That is why the picture mode exists.

### The menu

| Item | What it does |
|---|---|
| Status line | What is on the clipboard now, or why a copy couldn't be converted |
| **Enhance ChemDraw Copies** | Turns ChemClip on or off. When off, ChemDraw's normal clipboard is left alone |
| **Paste into Office As → Vector Graphic (SVG)** | Default. Sharp at any size and on Windows, and editable again in ChemDraw |
| **Paste into Office As → High-Resolution Picture (600 dpi)** | A 600 dpi image, for PNG export. Can't be turned back into a ChemDraw structure |
| **Open at Login** | Starts ChemClip automatically when you log in |
| **How ChemClip Works…** | A short summary of these instructions |
| **Show Clipboard Formats…** | Lists what is on the clipboard, for troubleshooting |
| **Quit ChemClip** | Stops ChemClip; copies then behave as without it |

The mode applies to the next copy. If you switch it, copy the drawing in ChemDraw again. Copies from apps other than ChemDraw are never changed.

### If something looks wrong

- **The paste is blurry or is a plain picture:** check that ChemClip is running (the icon is in the menu bar and not dimmed), then copy in ChemDraw again and paste. Pictures pasted before ChemClip was running stay blurry; paste them again.
- **ChemDraw pastes a picture instead of a structure:** copy the picture in Office with ChemClip running. Only vector graphics pasted with ChemClip carry the structure.
- **Pasting in Office for the web, or into a virtual machine:** browsers and VM clipboards carry only bitmaps, so ChemClip can't help there. Paste in desktop Office on the Mac and open the saved file instead.

## Why ChemDraw pastes go blurry on a Mac

On Windows, ChemDraw puts an EMF (Windows' vector picture format) on the clipboard and Office stores it as-is. On a Mac, ChemDraw provides a PDF. Office for Mac shows the PDF on screen, but stores it with a small bitmap as the only thing Windows can read; for one test structure it was 56 × 176 pixels. Windows Office and Save as Picture use that bitmap. More in [docs/RESEARCH.md](docs/RESEARCH.md).

## How it works

When ChemDraw copies a drawing, ChemClip reads the drawing instructions in its PDF using macOS's own CoreGraphics and CoreText. Atom labels become outlines from the fonts embedded in the PDF. ChemClip then adds Office's own clipboard format to the same clipboard entry:

| On the clipboard | Used by |
|---|---|
| Office picture (`com.microsoft.Art--GVML-ClipFormat`): SVG with a vector EMF fallback | Word, PowerPoint, Excel, Outlook |
| ChemDraw CDX, MOL and SMILES, unchanged | ChemDraw (editable structure), other chemistry apps |
| ChemDraw's PDF, unchanged | Keynote, Pages, Preview, Mail and others |

Office stores the SVG byte for byte and treats the picture as a Graphic. Microsoft 365 and Office 2019 or later on Windows draw the SVG; older versions use a high-resolution fallback image. No generic image format (PNG, TIFF) is added, because ChemDraw would paste that instead of its own editable data.

**Back to ChemDraw.** Vector graphics carry ChemDraw's structure data (CDX) inside the SVG, in an XML comment that renderers ignore. It stays in saved files. When you copy such a picture in Office, ChemClip puts the CDX back on the clipboard, and ChemDraw pastes an editable structure. This works from reopened files too. Office copies of other pictures are left alone.

## Privacy

- Conversion happens in memory. ChemClip writes no files, keeps no clipboard history and makes no network connections. Converted pictures disappear from the clipboard when you copy something else.
- The only thing ChemClip stores is its two menu settings, in macOS preferences.
- **Structures travel with your files.** Anyone you send a document to can paste its vector ChemClip graphics into ChemDraw as structures. For unpublished chemistry, use High-Resolution Picture mode.

## Limits

- Drawings containing embedded images, gradients, transparency or patterns go to Office as a 600 dpi picture instead of a vector, so nothing is silently dropped. The menu says why.
- Clipping paths are not reproduced. ChemDraw's clipboard PDFs don't use them for drawing content.
- Text comes from the fonts embedded in ChemDraw's PDF. A font that is neither embedded nor installed falls back to a system font.
- Double-clicking a pasted picture in Office doesn't open ChemDraw; copy and paste it instead. ChemClip must be running for both directions.
- If you paste within about half a second of copying, you may get ChemDraw's original clipboard. Paste again.

Verified on macOS 26.3 with ChemDraw 26.1 and PowerPoint 16.88, and by opening the saved deck in PowerPoint (Microsoft 365) on Windows. Word, Excel and Outlook have not been tested yet. See [docs/VALIDATION.md](docs/VALIDATION.md).

## Build from source

Requires macOS 13 or later and Xcode or the Command Line Tools (Swift 5.9+). There are no third-party dependencies.

```sh
bash scripts/build-app.sh      # dist/ChemClip.app (universal with full Xcode)
bash scripts/package.sh        # also dist/ChemClip-1.0.0.zip and dist/ChemClip.dmg (asks Finder to lay out the window)
swift scripts/make-icon.swift  # redraws Resources/AppIcon.icns (the disk image background is drawn by scripts/make-dmg-background.swift)
swift test
```

Builds are signed ad hoc. Set `CHEMCLIP_SIGN_IDENTITY` to sign with a certificate. Distributing without the Open prompt requires a Developer ID certificate and Apple notarization.

The tests draw PDFs with Quartz, the same producer ChemDraw uses for its clipboard, and work on private pasteboards, never your clipboard. Run them in a logged-in desktop session.

`dist/chemclip-tool` mirrors the app from Terminal: `inspect` lists clipboard type names, `enhance [--picture]` converts the current ChemDraw copy once, and `emf INPUT.pdf OUTPUT.emf` converts a PDF file for testing. `scripts/inspect-pptx.py` lists and extracts the SVG pictures stored in a saved `.pptx`.

## License

[MIT](LICENSE) © 2026 Mosè Simone Galluzzo
