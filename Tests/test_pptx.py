import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("inspect_pptx", Path(__file__).parents[1] / "scripts/inspect-pptx.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PPTXTests(unittest.TestCase):
    def make_deck(self, directory, target="../media/image1.svg", external=False, reference=True):
        path = Path(directory) / "test.pptx"
        self.svg = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M0 0L10 10"/></svg>'
        with zipfile.ZipFile(path, "w") as archive:
            entry = '<s:svgBlip r:embed="rId3"/>' if reference else ''
            archive.writestr("ppt/slides/slide1.xml", f'<p xmlns:s="{module.SVG}" xmlns:r="{module.REL}">{entry}</p>')
            mode = 'TargetMode="External"' if external else ''
            archive.writestr("ppt/slides/_rels/slide1.xml.rels", f'<Relationships><Relationship Id="rId3" Target="{target}" {mode}/></Relationships>')
            archive.writestr("ppt/media/image1.svg", self.svg)
        return path

    def test_references_and_lossless_extraction(self):
        with tempfile.TemporaryDirectory() as d:
            deck = self.make_deck(d)
            report = module.inspect(deck, Path(d) / "extract")
            self.assertEqual(len(report), 1)
            self.assertFalse(report[0]["contains_raster_images"])
            self.assertEqual(Path(report[0]["extracted_to"]).read_bytes(), self.svg)
            with self.assertRaises(FileExistsError):
                module.inspect(deck, Path(d) / "extract")

    def test_unreferenced_media_does_not_prove_slide_is_vector(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(module.inspect(self.make_deck(d, reference=False)), [])

    def test_external_and_traversal_targets_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            for target, external in [("https://example.org/a.svg", True), ("../../../a.svg", False)]:
                with self.assertRaises(ValueError):
                    module.inspect(self.make_deck(d, target, external))


if __name__ == "__main__":
    unittest.main()
