"""Downloads the public-domain / CC0 benchmark photos from Wikimedia Commons.
Usage: python3 fetch_bench_photos.py <out-dir>"""
import json, os, sys, time, urllib.parse, urllib.request

PHOTOS = {
    # Portraits across skin tones (NASA, public domain)
    "portrait-chawla": "File:Kalpana Chawla, NASA photo portrait in orange suit.jpg",
    "portrait-melvin": "File:NASA astronaut Leland D. Melvin with his dogs Jake and Scout.jpg",
    "portrait-clark": "File:Laurel Clark, NASA photo portrait in blue suit.jpg",
    # Low light (CC0)
    "night-budapest": "File:Széchenyi Chain Bridge in Budapest at night.jpg",
    "night-quebec": "File:Petit Champlain at night, Quebec city.jpg",
    # High contrast / backlit (CC0, public domain)
    "backlit-selfie": "File:Man taking backlit selfie (Unsplash).jpg",
    "bw-portrait": "File:Bo Diddley (1957 publicity portrait).jpg",
    # Landscape at dusk (CC0)
    "dusk-frontenac": "File:Chateau Frontenac at dusk in Quebec City.jpg",
}
UA = {"User-Agent": "EchoAppBenchmark/1.0 (open-source iOS app; CI image-quality benchmark)"}
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for name, title in PHOTOS.items():
    for attempt in range(5):
        try:
            q = urllib.parse.urlencode({"action": "query", "titles": title, "prop": "imageinfo",
                                        "iiprop": "url", "iiurlwidth": "1600", "format": "json"})
            data = json.load(urllib.request.urlopen(urllib.request.Request(
                "https://commons.wikimedia.org/w/api.php?" + q, headers=UA), timeout=30))
            info = next(iter(data["query"]["pages"].values()))["imageinfo"][0]
            img = urllib.request.urlopen(urllib.request.Request(info["thumburl"], headers=UA), timeout=60).read()
            open(os.path.join(out, name + ".jpg"), "wb").write(img)
            print("ok", name, len(img))
            break
        except Exception as e:
            print("retry", name, e)
            time.sleep(20 * (attempt + 1))
    time.sleep(4)
print(len(os.listdir(out)), "photos")
