#!/bin/bash
# Regenerate Resources/Gauge.icns + Resources/gauge_logo.png from the canonical
# brand source, Assets/gauge-app-icon.png (any square PNG with a transparent
# surround). The rounded-rect body is detected from alpha and fitted to
# Apple's icon grid (824px body on a 1024px canvas), so the icon sits at the
# same size as other apps in the Dock; near-invisible speckle (alpha < 12) is
# dropped so it can't fringe on light backgrounds.
#
# Override: SOURCE=path/to/icon.png ./scripts/make-icns.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${SOURCE:-Assets/gauge-app-icon.png}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Gauge.iconset"

python3 - "$SOURCE" "$WORK" <<'PY'
import sys
from PIL import Image
source, work = sys.argv[1], sys.argv[2]
src = Image.open(source).convert("RGBA")
r, g, b, a = src.split()
a = a.point(lambda v: 0 if v < 12 else v)
src = Image.merge("RGBA", (r, g, b, a))
body = a.point(lambda v: 255 if v > 200 else 0).getbbox()
scale = 824 / max(body[2] - body[0], body[3] - body[1])
big = src.resize((round(src.width * scale), round(src.height * scale)), Image.LANCZOS)
cx = (body[0] + body[2]) / 2 * scale
cy = (body[1] + body[3]) / 2 * scale
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
canvas.alpha_composite(big, (round(512 - cx), round(512 - cy)))
canvas.save(f"{work}/icon_1024.png")
for size in (16, 32, 128, 256, 512):
    for k in (1, 2):
        suffix = "@2x" if k == 2 else ""
        canvas.resize((size * k, size * k), Image.LANCZOS).save(
            f"{work}/Gauge.iconset/icon_{size}x{size}{suffix}.png")
PY

iconutil -c icns "$WORK/Gauge.iconset" -o Resources/Gauge.icns
cp "$WORK/icon_1024.png" Resources/gauge_logo.png
echo "wrote Resources/Gauge.icns and Resources/gauge_logo.png from $SOURCE"
