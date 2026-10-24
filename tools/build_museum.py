"""Resizes downloaded public-domain artwork images (Wikimedia Commons) into the
app bundle and trims the catalog to the works that are present.
Usage: python3 build_museum.py <downloaded-images-dir> <Echo/Resources/Museum>"""
import json, os, sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
catalog_path = os.path.join(dst, "museum-catalog.json")
full_path = os.path.join(os.path.dirname(__file__), "museum-catalog.full.json")
works = json.load(open(full_path))
present = []
for work in works:
    path = os.path.join(src, work["id"] + ".jpg")
    if not os.path.exists(path):
        continue
    img = Image.open(path).convert("RGB")
    img.thumbnail((320, 320), Image.LANCZOS)
    img.save(os.path.join(dst, "museum-" + work["id"] + ".jpg"), quality=85)
    present.append(work)
json.dump(present, open(catalog_path, "w"), ensure_ascii=False, indent=1)
print(len(present), "works")
