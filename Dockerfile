# Cantaloupe IIIF Image API server — minimal container, latest LTS throughout.
#
# Deliberately small and boring:
#   * Ubuntu 26.04 LTS + OpenJDK 25 LTS.
#   * No config templating. Cantaloupe reads configuration from the environment
#     natively, and the environment takes priority over the config file, so a
#     templating entrypoint would only reimplement a built-in feature. Key names
#     are the config key uppercased with non-alphanumerics replaced by
#     underscores: `http.port` -> HTTP_PORT, `S3Source.endpoint` ->
#     S3SOURCE_ENDPOINT. See the sample config for the full list of keys.
#   * Only the native libraries Cantaloupe actually uses (see below).
#
# What is intentionally NOT installed:
#   * ffmpeg      — only for FfmpegProcessor, which extracts still frames from
#                   *video*. ~316 MB across ~282 packages; skip unless you serve
#                   video.
#   * libtiff*    — TIFF is decoded in pure Java by Java2dProcessor. The C
#                   library is only needed by the Kakadu binaries, which are
#                   proprietary, x86-64-only, and not shipped here.
#   * Kakadu      — proprietary, and its libs/Makefile are Linux-x86-64 only, so
#                   it could never run on arm64. JPEG2000 falls back to
#                   OpenJpegProcessor.
#   * python/perl — not needed by anything here.

ARG CANTALOUPE_VERSION=5.0.7

# --- fetch stage: keep curl/unzip and the archive out of the final image -------
FROM ubuntu:26.04 AS fetch
ARG CANTALOUPE_VERSION
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq --no-install-recommends \
       ca-certificates curl unzip > /dev/null
RUN curl -fsSL -o /tmp/cantaloupe.zip \
      "https://github.com/cantaloupe-project/cantaloupe/releases/download/v${CANTALOUPE_VERSION}/Cantaloupe-${CANTALOUPE_VERSION}.zip" \
    && unzip -qq /tmp/cantaloupe.zip -d /tmp/unpacked \
    && mv "/tmp/unpacked/cantaloupe-${CANTALOUPE_VERSION}" /opt/cantaloupe \
    # `deps/` holds only Kakadu's Linux-x86-64 native libs — useless here.
    && rm -rf /opt/cantaloupe/deps

# --- runtime stage ------------------------------------------------------------
FROM ubuntu:26.04
ARG CANTALOUPE_VERSION

LABEL org.opencontainers.image.title="Cantaloupe IIIF Image API server" \
      org.opencontainers.image.description="Minimal multi-arch Cantaloupe image on Ubuntu 26.04 LTS + Java 25 LTS." \
      org.opencontainers.image.source="https://github.com/drewsilcock/cantaloupe-docker" \
      org.opencontainers.image.licenses="MIT"

# openjdk-25-jre-headless : latest LTS JVM (Cantaloupe requires Java 11+)
# libturbojpeg0           : libjpeg-turbo, used by Cantaloupe for *writing* JPEG
#                           derivatives (the manual: "libjpeg-turbo, if
#                           available, is used for writing JPEGs")
# libopenjp2-tools        : opj_decompress, for JPEG2000 sources (~2 MB; drop it
#                           if you only ever serve TIFF/JPEG)
# ca-certificates         : TLS trust for HTTPS sources (e.g. S3)
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq --no-install-recommends \
       openjdk-25-jre-headless libturbojpeg0 libopenjp2-tools ca-certificates > /dev/null \
    # Cantaloupe looks for libjpeg-turbo here. Resolve the multiarch directory
    # rather than hard-coding x86_64, so this works on arm64 too; `ln -s` would
    # otherwise create a dangling symlink and silently disable libjpeg-turbo.
    && mkdir -p /opt/libjpeg-turbo/lib \
    && ln -s "$(ls /usr/lib/*/libturbojpeg.so.0 | head -n1)" /opt/libjpeg-turbo/lib/libturbojpeg.so \
    && test -e /opt/libjpeg-turbo/lib/libturbojpeg.so \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /opt/cantaloupe /opt/cantaloupe

# uid 101 is fixed on purpose: a named volume mounted at the cache path inherits
# ownership from the image, and a moving uid silently breaks cache writes —
# Cantaloupe then answers 200 with an empty body and logs nothing.
RUN useradd --system --uid 101 --gid nogroup --no-create-home --shell /usr/sbin/nologin cantaloupe \
    && cp /opt/cantaloupe/cantaloupe.properties.sample /etc/cantaloupe.properties \
    && mkdir -p /var/cache/cantaloupe \
    && chown cantaloupe:nogroup /var/cache/cantaloupe /etc/cantaloupe.properties

ENV CONFIG_FILE=/etc/cantaloupe.properties \
    # Percentage of the container's memory limit to use as max heap. Preferred
    # over a fixed -Xmx because it tracks `docker run -m` / compose `mem_limit`.
    HEAP_PERCENTAGE=75 \
    JAVA_OPTS="" \
    # --- defaults, all overridable at run time (env beats the config file) ---
    HTTP_HOST=0.0.0.0 \
    HTTP_PORT=8182 \
    # Stock sample ships 10 MP, which caps the sizes advertised in info.json and
    # is low for large heritage masters.
    MAX_PIXELS=100000000 \
    FILESYSTEMCACHE_PATHNAME=/var/cache/cantaloupe

USER cantaloupe
EXPOSE 8182
VOLUME /var/cache/cantaloupe

ENTRYPOINT ["/bin/sh", "-c", "exec java -XX:MaxRAMPercentage=${HEAP_PERCENTAGE} ${JAVA_OPTS} -Dcantaloupe.config=${CONFIG_FILE} -cp /opt/cantaloupe/cantaloupe-*.jar edu.illinois.library.cantaloupe.StandaloneEntry"]
