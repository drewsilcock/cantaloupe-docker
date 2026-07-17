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

# The 2x2 that the pyramid-layout tests assert on: {classic, BigTIFF} x {pages,
# sub-IFDs}. libvips stores levels as pages by default and as sub-IFDs with
# `subifd` — and that single flag is what decides whether Cantaloupe can use the
# pyramid at all. See "Serving TIFF" in the README.

# Tiled + pyramidal, levels stored as PAGES — the layout Cantaloupe needs to
# serve reduced-resolution requests from the pyramid.
vips copy source.v pyramid.tif"[$tiled]"

# Same, but BigTIFF. Cantaloupe reads these fine; the folklore that it cannot is
# really about *sub-IFD* pyramids, which are a different thing.
vips copy source.v pyramid-bigtiff.tif"[$tiled,bigtiff]"

# Levels as SUB-IFDs. Parses, but Cantaloupe ignores the pyramid and decodes the
# full-resolution base for every request.
vips copy source.v pyramid-subifd.tif"[$tiled,subifd]"

# BigTIFF + sub-IFDs: the combination that actually breaks. A BigTIFF sub-IFD
# pyramid stores its offsets as TIFF type 18 (IFD8), which the bundled reader
# cannot parse.
vips copy source.v pyramid-subifd-bigtiff.tif"[$tiled,subifd,bigtiff]"

# Plain, non-pyramidal formats, to cover the ordinary paths.
vips copy source.v plain.jpg"[Q=85]"
vips copy source.v plain.png
# JPEG2000 exercises OpenJpegProcessor, i.e. that libopenjp2-tools is present
# and actually usable.
vips copy source.v plain.jp2

rm -f source.v
ls -l | awk 'NR>1 {printf "  %-24s %6.0f KB\n", $9, $5/1024}'
