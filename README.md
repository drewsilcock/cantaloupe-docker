# cantaloupe-docker

A small, multi-arch container image for the [Cantaloupe](https://cantaloupe-project.github.io/)
IIIF Image API server.

```
docker run -p 8182:8182 -v /path/to/images:/imageroot ghcr.io/drewsilcock/cantaloupe:latest
```

- **linux/amd64 + linux/arm64** — runs natively on Apple Silicon and arm64 servers.
- **Latest LTS throughout** — Ubuntu 26.04 LTS, OpenJDK 25 LTS.
- **~490 MB**, about half the size of the common alternative.
- **No config templating.** Cantaloupe already reads its configuration from the
  environment; this image doesn't reinvent that.

## Configuration

Cantaloupe consults **the environment first, then the config file**. Key names are
the config key uppercased, with non-alphanumerics replaced by underscores:

| Config key                              | Environment variable                          |
| --------------------------------------- | --------------------------------------------- |
| `http.port`                             | `HTTP_PORT`                                   |
| `source.static`                         | `SOURCE_STATIC`                               |
| `S3Source.endpoint`                     | `S3SOURCE_ENDPOINT`                           |
| `S3Source.BasicLookupStrategy.bucket.name` | `S3SOURCE_BASICLOOKUPSTRATEGY_BUCKET_NAME` |

The full key list is in `/opt/cantaloupe/cantaloupe.properties.sample` inside the
image, or the [configuration manual](https://cantaloupe-project.github.io/manual/5.0/configuration.html).

Image-specific variables:

| Variable          | Default                  | Purpose                                                    |
| ----------------- | ------------------------ | ---------------------------------------------------------- |
| `HEAP_PERCENTAGE` | `75`                     | Max heap as a share of the container memory limit           |
| `JAVA_OPTS`       | *(empty)*                | Extra JVM flags                                             |
| `CONFIG_FILE`     | `/etc/cantaloupe.properties` | Config file path                                        |

Defaults differing from the stock sample config: `HTTP_HOST=0.0.0.0`,
`MAX_PIXELS=100000000` (the stock 10 MP caps the sizes advertised in `info.json`,
which is low for large heritage masters), `FILESYSTEMCACHE_PATHNAME=/var/cache/cantaloupe`.
All are overridable.

## Caching

Cantaloupe ships with the derivative cache **disabled**, which makes every request
recompute and re-fetch — warm requests are as slow as cold ones. Enable it:

```yaml
environment:
  CACHE_SERVER_DERIVATIVE: FilesystemCache
  CACHE_SERVER_DERIVATIVE_ENABLED: "true"
  CACHE_SERVER_DERIVATIVE_TTL_SECONDS: "0"
volumes:
  - cantaloupecache:/var/cache/cantaloupe
```

Measured on a 436 MP pyramidal TIFF over a slow S3 link: cold ~3.4 s, warm ~0.005 s.

The container runs as **uid 101**. A named volume mounted at the cache path
inherits ownership from the image, so this generally just works — but if the
volume was created by a different image running as root, Cantaloupe cannot write
it and **fails silently: HTTP 200 with an empty body, nothing in the logs**. Fix
with `docker run --rm -v <volume>:/c alpine chown -R 101:65534 /c`.

## Serving TIFF

For efficient deep zoom, masters must be **tiled and pyramidal**. One trap: the
pyramid levels must be stored as **pages (main IFDs), not sub-IFDs**. With
sub-IFD levels Cantaloupe decodes the full-resolution base for every request —
~10x slower on a small test image, and heap exhaustion on a large one.

With libvips, that means leaving `subifd` off (the default):

```
vips copy in.tif out.tif[tile,tile-width=256,tile-height=256,pyramid,compression=jpeg,Q=90]
```

Verify with `vipsheader -a out.tif`: it should report `n-pages`, not `n-subifds`.

This is asserted by the tests, not folklore. Cantaloupe logs the resolution it
decodes from, so `test/run-tests.sh` asks each fixture for `/full/200,` (from a
1600x1200 source with a 200x150 level) and checks the log:

```
pyramid.tif         Acquiring region 0,0/200x150 from 200x150 image      <- uses the pyramid
pyramid-subifd.tif  Acquiring region 0,0/1600x1200 from 1600x1200 image  <- decodes the base
```

## What's not included

| Omitted | Why |
| ------- | --- |
| `ffmpeg` | Only for `FfmpegProcessor`, which extracts still frames from **video**. Costs ~316 MB across ~282 packages. |
| `libtiff` | TIFF is decoded in pure Java by `Java2dProcessor`. The C library is only needed by the Kakadu binaries. |
| Kakadu | Proprietary, and its libraries are Linux-x86-64 only — it could never run on arm64. JPEG2000 is handled by `OpenJpegProcessor` instead (`libopenjp2-tools` **is** included). |

## JPEG2000

JP2 works, but it needs pinning — which this image does for you:

```
PROCESSOR_SELECTION_STRATEGY=ManualSelectionStrategy
PROCESSOR_MANUALSELECTIONSTRATEGY_JP2=OpenJpegProcessor
PROCESSOR_MANUALSELECTIONSTRATEGY_FALLBACK=Java2dProcessor
```

Cantaloupe's default `AutomaticSelectionStrategy` tries `KakaduNativeProcessor`
first for JP2 and, when the Kakadu JNI library is missing — as it is in any build
without a Kakadu licence — it does **not** fall back. Every JP2 request 500s with
`UnsatisfiedLinkError: no kdu_jni in java.library.path`. Shipping the OpenJPEG
decoder is not enough on its own; it has to be selected.

## Tests

```
./test/run-tests.sh                          # build and test locally
IMAGE=ghcr.io/drewsilcock/cantaloupe:5.0.7 ./test/run-tests.sh   # test a published image
```

Starts a container, serves the committed fixtures in `test/fixtures/` (pyramidal
TIFF, BigTIFF, JPEG, PNG, JP2, plus sub-IFD variants of the TIFFs) over the IIIF
Image API, and checks the bytes that come back — including that the returned JPEG really has the requested dimensions,
parsed from its SOF marker. A 200 alone proves little: the failure mode seen in
the wild is 200 with an empty body.

Tests require docker, curl, and python3.

## Licence

MIT for the packaging in this repository. Cantaloupe itself is distributed under
its own [licence](https://github.com/cantaloupe-project/cantaloupe/blob/develop/LICENSE.txt).
