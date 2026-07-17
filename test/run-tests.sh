#!/usr/bin/env bash
# End-to-end tests: start the image, serve the fixtures in test/fixtures/ over
# the IIIF Image API, and check the bytes that come back.
#
#   ./test/run-tests.sh                       # builds and tests the local Dockerfile
#   IMAGE=ghcr.io/…/cantaloupe:5.0.7 ./test/run-tests.sh   # tests a published image
#
# Needs docker, curl and python3. Nothing else — the fixtures are committed.
set -uo pipefail

cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-cantaloupe-test:local}"
PORT="${PORT:-38182}"
NAME="cantaloupe-tests-$$"
BASE="http://localhost:${PORT}/iiif/3"

if [ -z "${IMAGE_PREBUILT:-}" ] && [ "$IMAGE" = "cantaloupe-test:local" ]; then
  echo "Building $IMAGE …"
  docker build -q -t "$IMAGE" . > /dev/null
fi

cleanup() { docker rm -f "$NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Starting $IMAGE …"
docker run -d --name "$NAME" -p "${PORT}:8182" \
  -v "$PWD/test/fixtures:/imageroot:ro" \
  -e SOURCE_STATIC=FilesystemSource \
  -e FILESYSTEMSOURCE_BASICLOOKUPSTRATEGY_PATH_PREFIX=/imageroot/ \
  -e CACHE_SERVER_DERIVATIVE=FilesystemCache \
  -e CACHE_SERVER_DERIVATIVE_ENABLED=true \
  -e CACHE_SERVER_DERIVATIVE_TTL_SECONDS=0 \
  "$IMAGE" > /dev/null

for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "${BASE}/pyramid.tif/info.json" 2>/dev/null && break
  sleep 1
done

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $3, got $2"; fi; }

# --- info.json ---------------------------------------------------------------
echo "info.json reports the real image size"
for f in pyramid.tif pyramid-bigtiff.tif plain.jpg plain.png plain.jp2; do
  dims=$(curl -fsS "${BASE}/${f}/info.json" 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d['width']}x{d['height']}\")" 2>/dev/null)
  check "$f" "${dims:-<no response>}" "1600x1200"
done

# --- rendering ---------------------------------------------------------------
# Ask for a known output width and confirm the returned JPEG really is that
# size, parsed from its SOF marker. A 200 alone proves little: the failure mode
# we actually hit in the wild was 200 with an empty body.
echo "renders a real, correctly-sized JPEG tile"
jpeg_size() {
  python3 - "$1" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
if d[:2] != b'\xff\xd8': print("not-a-jpeg"); sys.exit()
i = 2
while i < len(d):
    if d[i] != 0xFF: print("bad-marker"); sys.exit()
    m = d[i+1]; i += 2
    if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7: continue
    ln = struct.unpack('>H', d[i:i+2])[0]
    if m in (0xC0, 0xC1, 0xC2, 0xC3):
        h, w = struct.unpack('>HH', d[i+3:i+7]); print(f"{w}x{h}"); sys.exit()
    i += ln
print("no-sof")
PY
}
tmp=$(mktemp -d)
for f in pyramid.tif pyramid-bigtiff.tif plain.jpg plain.png plain.jp2; do
  curl -fsS -o "$tmp/$f.jpg" "${BASE}/${f}/full/200,/0/default.jpg" 2>/dev/null
  if [ -s "$tmp/$f.jpg" ]; then check "$f -> full/200," "$(jpeg_size "$tmp/$f.jpg")" "200x150"
  else bad "$f -> full/200," "empty or missing body"; fi
done

echo "serves a region crop"
curl -fsS -o "$tmp/region.jpg" "${BASE}/pyramid.tif/400,300,512,512/256,/0/default.jpg" 2>/dev/null
check "pyramid.tif region 512px -> 256," "$(jpeg_size "$tmp/region.jpg")" "256x256"

# --- the silent-failure guard ------------------------------------------------
# If the cache directory is not writable, Cantaloupe answers 200 with
# Content-Length: 0 and logs nothing. Assert bytes, not status.
echo "cached responses still have a body (cache dir must be writable)"
url="${BASE}/pyramid.tif/0,0,256,256/128,/0/default.jpg"
curl -fsS -o /dev/null "$url" 2>/dev/null                    # populate cache
n=$(curl -fsS -o /dev/null -w '%{size_download}' "$url" 2>/dev/null)  # served from cache
if [ "${n:-0}" -gt 500 ]; then ok "cached tile is ${n} bytes"; else bad "cached tile" "got ${n:-0} bytes"; fi
cached=$(docker exec "$NAME" sh -c 'find /var/cache/cantaloupe -type f | wc -l' 2>/dev/null | tr -d ' ')
if [ "${cached:-0}" -gt 0 ]; then ok "derivative cache wrote ${cached} file(s)"; else bad "derivative cache" "nothing written"; fi

# --- configuration -----------------------------------------------------------
# The whole design rests on Cantaloupe reading config from the environment, so
# prove an env var actually reaches the running config. `maxArea` is
# min(max_pixels, width*height), so the fixture's own 1600x1200 = 1920000 wins
# against the image's 100 MP default; overriding *below* that shows through.
echo "configuration comes from the environment"
maxarea=$(curl -fsS "${BASE}/pyramid.tif/info.json" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('maxArea'))" 2>/dev/null)
check "default MAX_PIXELS exceeds the fixture, so maxArea is its own area" "$maxarea" "1920000"

docker rm -f "$NAME" > /dev/null 2>&1
docker run -d --name "$NAME" -p "${PORT}:8182" \
  -v "$PWD/test/fixtures:/imageroot:ro" \
  -e SOURCE_STATIC=FilesystemSource \
  -e FILESYSTEMSOURCE_BASICLOOKUPSTRATEGY_PATH_PREFIX=/imageroot/ \
  -e MAX_PIXELS=500000 "$IMAGE" > /dev/null
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "${BASE}/pyramid.tif/info.json" 2>/dev/null && break
  sleep 1
done
maxarea=$(curl -fsS "${BASE}/pyramid.tif/info.json" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('maxArea'))" 2>/dev/null)
check "MAX_PIXELS=500000 override is honoured" "$maxarea" "500000"

# --- report ------------------------------------------------------------------
rm -rf "$tmp"
echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || { echo; echo "--- container logs ---"; docker logs "$NAME" 2>&1 | tail -25; exit 1; }
