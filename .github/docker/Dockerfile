# Test container for the Arduino-wolfSSL library.
#
# Holds arduino-cli and the Espressif fork of QEMU. Used by the workflow
# .github/workflows/arduino-docker.yml and usable as-is on a workstation.
#
# Build, from the root of this repository:
#
#   docker build -t arduino-wolfssl-test .github/docker
#
# Run, with this repository mounted read-only at /repo:
#
#   docker run --rm -v "$PWD":/repo:ro arduino-wolfssl-test compile esp32:esp32:esp32
#   docker run --rm -v "$PWD":/repo:ro arduino-wolfssl-test qemu wolfssl_version
#
# Add  -v arduino15:/root/.arduino15  to keep downloaded board cores between runs.
#
# See arduino-test.sh for details.

FROM ubuntu:24.04

# Optional: full URL of an Espressif qemu-xtensa-softmmu linux tar.xz release.
# When empty, the latest release for this machine architecture is looked up.
ARG QEMU_URL=""

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bzip2 ca-certificates curl git jq python-is-python3 python3 \
        python3-serial shellcheck unzip xz-utils \
        libgcrypt20 libglib2.0-0t64 libpixman-1-0 libsdl2-2.0-0 libslirp0 \
        libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Arduino CLI
RUN curl -fsSL --retry 5 --retry-delay 10 \
        https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
        | BINDIR=/usr/local/bin sh \
    && arduino-cli version

# Espressif QEMU (xtensa, for the esp32)
RUN set -e; \
    url="$QEMU_URL"; \
    if [ -z "$url" ]; then \
        arch="$(uname -m)"; \
        url="$(curl -fsSL --retry 5 --retry-delay 10 \
                 https://api.github.com/repos/espressif/qemu/releases/latest \
               | jq -r --arg a "$arch" \
                 '.assets[].browser_download_url | select(test("qemu-xtensa-softmmu-.*-" + $a + "-linux-gnu\\.tar\\.xz$"))' \
               | head -n 1)"; \
    fi; \
    if [ -z "$url" ]; then echo "No Espressif QEMU download found"; exit 1; fi; \
    echo "Espressif QEMU: $url"; \
    mkdir -p /opt/qemu; \
    curl -fsSL --retry 5 --retry-delay 10 "$url" | tar -xJ -C /opt/qemu; \
    qemu_bin="$(find /opt/qemu -type f -name qemu-system-xtensa | head -n 1)"; \
    if [ -z "$qemu_bin" ]; then echo "qemu-system-xtensa not found in archive"; exit 1; fi; \
    ln -s "$qemu_bin" /usr/local/bin/qemu-system-xtensa; \
    qemu-system-xtensa --version

COPY arduino-test.sh /usr/local/bin/arduino-test.sh
RUN chmod +x /usr/local/bin/arduino-test.sh

ENTRYPOINT ["/usr/local/bin/arduino-test.sh"]
