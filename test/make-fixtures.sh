#!/usr/bin/env bash
# Regenerate the test images in test/fixtures/.
#
# The fixtures are committed, so running the tests needs nothing but Docker,
# python3 and curl. You only need this script (and libvips) to change them.
#
#   brew install vips   # or: apt-get install libvips-tools
#   ./test/make-fixtures.sh
#
# Patterns are deterministic (`vips eye` is a frequency/amplitude test chart),
# so regenerating produces byte-stable files and the diffs stay meaningful.
set -euo pipefail
cd "$(dirname "$0")/fixtures"

W=1600
H=1200

# A test chart, converted to 8-bit sRGB.
vips eye source.v "$W" "$H" --factor 0.9
vips cast source.v source8.v uchar
vips colourspace source8.v source.v srgb
rm -f source8.v

tiled="tile,tile-width=256,tile-height=256,pyramid,compression=jpeg,Q=90"

# Tiled + pyramidal, levels stored as PAGES (libvips default) — the layout
# Cantaloupe needs to serve reduced-resolution requests from the pyramid.
vips copy source.v pyramid.tif"[$tiled]"

# Same, but BigTIFF. Cantaloupe reads these fine; the folklore that it cannot is
# really about *sub-IFD* pyramids, which are a different thing (see README).
vips copy source.v pyramid-bigtiff.tif"[$tiled,bigtiff]"

# Plain, non-pyramidal formats, to cover the ordinary paths.
vips copy source.v plain.jpg"[Q=85]"
vips copy source.v plain.png
# JPEG2000 exercises OpenJpegProcessor, i.e. that libopenjp2-tools is present
# and actually usable.
vips copy source.v plain.jp2

rm -f source.v
ls -l | awk 'NR>1 {printf "  %-24s %6.0f KB\n", $9, $5/1024}'
