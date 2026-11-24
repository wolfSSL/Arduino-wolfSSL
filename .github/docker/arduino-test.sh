#!/bin/bash
#
# arduino-test.sh - test the Arduino-wolfSSL library inside the test container.
#
# Usage, with this repository mounted at /repo (see Dockerfile):
#
#   arduino-test.sh compile [FQBN]
#       Install the board core, then compile every example for that board
#       using compile-all-examples.sh and the board list from wolfssl-examples.
#       e.g. arduino-test.sh compile esp32:esp32:esp32
#
#   arduino-test.sh qemu [example]
#       Compile one example for the ESP32, boot it in Espressif QEMU and check
#       the serial output. Supported: wolfssl_version, wolfssl_AES_CTR
#       The TLS / DTLS examples need WiFi, which QEMU does not emulate.
#
# Optional environment variables:
#
#   REPO_DIR            Arduino-wolfSSL source directory. Default: /repo
#   EXAMPLES_REPO_OWNER GitHub owner of wolfssl-examples. Default: wolfSSL
#   BOARD_LIST          Board list file name there.       Default: board_list.txt
#   QEMU_TIMEOUT        Seconds to wait for the sketch.   Default: 90
#   OUTPUT_DIR          Where qemu mode leaves serial.log Default: /tmp/qemu-out

set -e

REPO_DIR="${REPO_DIR:-/repo}"
EXAMPLES_REPO_OWNER="${EXAMPLES_REPO_OWNER:-wolfSSL}"
BOARD_LIST="${BOARD_LIST:-board_list.txt}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-90}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/qemu-out}"

ARDUINO_ROOT="$HOME/Arduino/libraries"
WOLFSSL_LIB="$ARDUINO_ROOT/wolfssl"
EXAMPLES_RAW="https://raw.githubusercontent.com/$EXAMPLES_REPO_OWNER/wolfssl-examples/master/Arduino/sketches"

usage() {
    sed -n '3,25p' "$0"
    exit 1
}

# Same Arduino CLI setup as .github/workflows/arduino.yml
setup_arduino() {
    local core_id="$1"

    if [ ! -f "$HOME/.arduino15/arduino-cli.yaml" ]; then
        arduino-cli config init
    fi
    arduino-cli config set network.connection_timeout 600s
    arduino-cli config add board_manager.additional_urls https://www.pjrc.com/teensy/package_teensy_index.json
    arduino-cli config add board_manager.additional_urls https://arduino.esp8266.com/stable/package_esp8266com_index.json
    arduino-cli core update-index
    echo "Installing core: $core_id"
    arduino-cli core install "$core_id"
}

# Same library layout as .github/workflows/arduino.yml: the repo is the library.
install_wolfssl() {
    local f

    if [ ! -f "$REPO_DIR/library.properties" ]; then
        echo "ERROR: no library.properties in $REPO_DIR. Mount the repository there."
        exit 1
    fi
    rm -rf "$WOLFSSL_LIB"
    mkdir -p "$WOLFSSL_LIB"
    for f in "$REPO_DIR"/*; do
        if [ -f "$f" ]; then
            cp "$f" "$WOLFSSL_LIB/"
        fi
    done
    cp -r "$REPO_DIR/src"      "$WOLFSSL_LIB/src"
    cp -r "$REPO_DIR/examples" "$WOLFSSL_LIB/examples"

    WOLFSSL_VERSION="$(grep '^version=' "$WOLFSSL_LIB/library.properties" | cut -d= -f2 | tr -d '\r')"
    if [ -z "$WOLFSSL_VERSION" ]; then
        echo "ERROR: no version found in library.properties"
        exit 1
    fi
    echo "wolfSSL Arduino library version: $WOLFSSL_VERSION"
}

# Download one file from wolfssl-examples Arduino/sketches
fetch_example_file() {
    local name="$1"
    local dest="$2"

    echo "Fetching $EXAMPLES_RAW/$name"
    curl -fsSL --retry 5 --retry-delay 10 "$EXAMPLES_RAW/$name" -o "$dest"
    if [ ! -s "$dest" ]; then
        echo "ERROR: could not fetch $name"
        exit 1
    fi
}

do_compile() {
    local fqbn="$1"
    local core_id lib

    if [ -z "$fqbn" ]; then
        usage
    fi
    core_id="$(echo "$fqbn" | cut -d: -f1-2)"

    setup_arduino "$core_id"
    for lib in ArduinoJson WiFiNINA Ethernet Bridge; do
        arduino-cli lib install "$lib"
    done
    install_wolfssl

    fetch_example_file "$BOARD_LIST"            "$WOLFSSL_LIB/examples/board_list.txt"
    fetch_example_file "compile-all-examples.sh" "$WOLFSSL_LIB/examples/compile-all-examples.sh"

    cd "$WOLFSSL_LIB/examples"
    bash ./compile-all-examples.sh ./board_list.txt "$fqbn"
}

# Check that the serial log contains the given text.
must_have() {
    if grep -a -q -F "$1" "$SERIAL_LOG"; then
        echo "OK:   found \"$1\""
    else
        echo "FAIL: missing \"$1\""
        RESULT=1
    fi
}

do_qemu() {
    local example="$1"
    local fqbn="esp32:esp32:esp32"
    local build_dir="$OUTPUT_DIR/build"
    local flash_bin="$OUTPUT_DIR/flash.bin"
    local done_text merged qemu_pid found i

    SERIAL_LOG="$OUTPUT_DIR/serial.log"
    RESULT=0

    if [ -z "$example" ]; then
        usage
    fi

    setup_arduino "esp32:esp32"
    install_wolfssl

    # The line each sketch prints last; seeing it means the run finished.
    case "$example" in
        wolfssl_version) done_text="wolfSSL Version: $WOLFSSL_VERSION" ;;
        wolfssl_AES_CTR) done_text="===== end =====" ;;
        *)
            echo "ERROR: no expected output defined for example: $example"
            exit 1
            ;;
    esac

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    echo "Compiling $example for $fqbn"
    arduino-cli compile --fqbn "$fqbn" --output-dir "$build_dir" "$WOLFSSL_LIB/examples/$example"

    # The esp32 core writes one image holding the bootloader, the partition
    # table and the application: [sketch].ino.merged.bin
    merged="$(find "$build_dir" -maxdepth 1 -name '*.merged.bin' | head -n 1)"
    if [ -z "$merged" ]; then
        echo "ERROR: no *.merged.bin found in build output:"
        ls -al "$build_dir"
        exit 1
    fi
    cp "$merged" "$flash_bin"
    # QEMU only accepts flash images of 2, 4, 8 or 16 MB.
    truncate -s 4M "$flash_bin"

    echo "Booting $example in QEMU, waiting up to $QEMU_TIMEOUT seconds"
    : > "$SERIAL_LOG"
    qemu-system-xtensa -nographic -machine esp32 \
        -drive "file=$flash_bin,if=mtd,format=raw" \
        -global driver=timer.esp32.timg,property=wdt_disable,value=true \
        -serial "file:$SERIAL_LOG" -monitor none > "$OUTPUT_DIR/qemu.log" 2>&1 &
    qemu_pid=$!

    found=0
    for ((i = 0; i < QEMU_TIMEOUT; i++)); do
        if grep -a -q -F "$done_text" "$SERIAL_LOG"; then
            found=1
            break
        fi
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            echo "QEMU exited early"
            break
        fi
        sleep 1
    done
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true

    echo "---------------- QEMU messages ----------------"
    cat "$OUTPUT_DIR/qemu.log"
    echo "---------------- serial output ----------------"
    cat "$SERIAL_LOG"
    echo
    echo "-----------------------------------------------"

    if [ "$found" -ne 1 ]; then
        echo "FAIL: did not see \"$done_text\" within $QEMU_TIMEOUT seconds"
        exit 1
    fi

    case "$example" in
        wolfssl_version)
            must_have "wolfSSL setup complete!"
            must_have "wolfSSL Version: $WOLFSSL_VERSION"
            ;;
        wolfssl_AES_CTR)
            must_have "wolfSSL library version: $WOLFSSL_VERSION"
            must_have "** SUCCESS ** deciphered data matches input data."
            must_have "===== end ====="
            # Every ExpectIntEQ in the sketch prints OK or FAIL.
            if grep -a -q "FAIL" "$SERIAL_LOG"; then
                echo "FAIL: the sketch reported a failure:"
                grep -a -n "FAIL" "$SERIAL_LOG"
                RESULT=1
            fi
            ;;
    esac

    if [ "$RESULT" -ne 0 ]; then
        echo "FAIL: $example on $fqbn in QEMU"
        exit 1
    fi
    echo "PASS: $example on $fqbn in QEMU"
}

case "$1" in
    compile) do_compile "$2" ;;
    qemu)    do_qemu    "$2" ;;
    *)       usage ;;
esac
