#!/usr/bin/env python3
"""Find SVGs actually referenced by slides; optionally extract their original bytes.

Uses Python's standard library only. Does not modify the presentation.
"""
import argparse
import json
import posixpath
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

MAX_MEMBER = 32 * 1024 * 1024
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
SVG = "http://schemas.microsoft.com/office/drawing/2016/SVG/main"


def inspect(path, output=None):
    report = []
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())

        def read(name):
            info = archive.getinfo(name)
            if info.file_size > MAX_MEMBER:
                raise ValueError(f"ZIP member exceeds 32 MB: {name}")
            return archive.read(name)

        for slide in sorted(n for n in names if n.startswith("ppt/slides/slide") and n.endswith(".xml") and "/_rels/" not in n):
            rels_path = posixpath.join(posixpath.dirname(slide), "_rels", posixpath.basename(slide) + ".rels")
            rels = {} if rels_path not in names else {
                e.attrib["Id"]: e.attrib
                for e in ET.fromstring(read(rels_path))
            }
            embeds = ET.fromstring(read(slide)).iter(f"{{{SVG}}}svgBlip")
            for element in embeds:
                rid = element.get(f"{{{REL}}}embed")
                relation = rels.get(rid, {})
                target = relation.get("Target", "")
                if relation.get("TargetMode") == "External" or not target:
                    raise ValueError(f"Unresolved or external SVG reference in {slide}: {rid}")
                member = posixpath.normpath(posixpath.join(posixpath.dirname(slide), target)) if not target.startswith("/") else target.lstrip("/")
                if not member.startswith("ppt/media/") or not member.lower().endswith(".svg"):
                    raise ValueError(f"Unexpected SVG target: {member}")
                data = read(member)
                root = ET.fromstring(data)
                if root.tag != "{http://www.w3.org/2000/svg}svg":
                    raise ValueError(f"Not an SVG: {member}")
                record = {"slide": slide, "svg": member, "bytes": len(data),
                          "contains_raster_images": any(e.tag.rsplit("}", 1)[-1] == "image" for e in root.iter())}
                if output is not None:
                    output = Path(output)
                    output.mkdir(parents=True, exist_ok=True)
                    destination = output / (Path(slide).stem + "-" + str(len(report) + 1) + "-" + Path(member).name)
                    with destination.open("xb") as stream:
                        stream.write(data)
                    record["extracted_to"] = str(destination)
                report.append(record)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("presentation", type=Path)
    parser.add_argument("--extract", type=Path, help="Extract referenced SVGs into this directory; never overwrite files")
    args = parser.parse_args()
    try:
        result = inspect(args.presentation, args.extract)
        print(json.dumps({"referenced_svg_count": len(result), "images": result}, indent=2))
        if not result:
            print("No slide SVG references found. This deck does not establish SVG vector preservation.")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
        parser.exit(1, f"Cannot inspect presentation: {error}\n")
