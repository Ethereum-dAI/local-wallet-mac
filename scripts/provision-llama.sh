#!/bin/bash
# Assemble the pinned llama.cpp prefix declared in local-llm/LLAMA_CPP_PIN.
#
# Downloads the pinned upstream release asset from GitHub, verifies it against
# the sha256 in the pin, and assembles a repo-local prefix at .llama/current:
#
#   .llama/<release>/lib      <- dylibs from the release asset
#   .llama/<release>/include  <- headers vendored at local-llm/third_party/llama_cpp_api
#
# Homebrew is not consulted. GitHub release assets are immutable, so every
# contributor and CI run gets identical bytes and `brew upgrade` cannot move the
# build off the pin. See local-llm/LLAMA_CPP_PIN for why this mechanism rather
# than Homebrew bottles.
#
# Idempotent: re-running with an unchanged pin is a no-op, so this is safe to
# call from build-ffi.sh and CI on every build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$REPO_ROOT/local-llm/LLAMA_CPP_PIN"
LLAMA_DIR="$REPO_ROOT/.llama"
CACHE_DIR="$LLAMA_DIR/cache"
API_HEADERS="$REPO_ROOT/local-llm/third_party/llama_cpp_api"
COMMON_HEADERS="$REPO_ROOT/local-llm/Sources/CLlamaBridge/third_party/llama_cpp_common"

# An explicit prefix wins over the pin (release packaging with a hand-built
# llama.cpp, or a deliberate Homebrew opt-in). Package.swift applies the same
# precedence, so provisioning here would just be wasted work.
if [[ -n "${LOCAL_LLAMA_PREFIX:-}" ]]; then
    echo "LOCAL_LLAMA_PREFIX=$LOCAL_LLAMA_PREFIX is set; skipping pinned provisioning."
    exit 0
fi

if [[ ! -f "$PIN_FILE" ]]; then
    echo "ERROR: Missing pin file: $PIN_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PIN_FILE"

: "${LLAMA_CPP_RELEASE:?LLAMA_CPP_RELEASE not set in $PIN_FILE}"
: "${LLAMA_CPP_COMMIT:?LLAMA_CPP_COMMIT not set in $PIN_FILE}"
: "${LLAMA_CPP_ASSET:?LLAMA_CPP_ASSET not set in $PIN_FILE}"
: "${LLAMA_CPP_SHA256:?LLAMA_CPP_SHA256 not set in $PIN_FILE}"

PREFIX="$LLAMA_DIR/$LLAMA_CPP_RELEASE"
STAMP="$PREFIX/.pin-stamp"

for tool in shasum curl tar otool; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: Required tool not found: $tool" >&2
        exit 1
    }
done

# --- Coherence gate: vendored headers must match the pinned commit ------------
# The dylibs come from the release asset; the headers are vendored in-repo. A
# bump that updates one and not the other is an ABI mismatch, and because the
# mangled C++ symbol names do not change it fails as silent runtime corruption
# rather than as a link error. So refuse to provision a disagreeing pair.
check_vendored_commit() {
    local commit_file="$1" label="$2"
    if [[ ! -f "$commit_file" ]]; then
        echo "ERROR: Missing vendored-header provenance file: $commit_file" >&2
        exit 1
    fi
    local declared
    declared="$(awk '/^# Pinned commit:/ {print $4; exit}' "$commit_file")"
    if [[ "$declared" != "$LLAMA_CPP_COMMIT" ]]; then
        echo "ERROR: $label headers are vendored from a different commit than the pin." >&2
        echo "  pin ($PIN_FILE):  $LLAMA_CPP_COMMIT" >&2
        echo "  $label:  ${declared:-<none found>}" >&2
        echo "  Re-vendor the headers from the pinned commit, or fix the pin." >&2
        echo "  See $commit_file for the procedure." >&2
        exit 1
    fi
}
check_vendored_commit "$API_HEADERS/COMMIT" "llama_cpp_api"
check_vendored_commit "$COMMON_HEADERS/COMMIT" "llama_cpp_common"

# --- Fast path: prefix already matches the pin --------------------------------
# The fingerprint covers the pin file and the vendored public headers, so
# editing either re-provisions. It deliberately does NOT cover the prefix path:
# the staged dylibs use @rpath install names, so the prefix is relocatable and
# moving the repo needs a Swift rebuild, not a re-provision.
fingerprint() {
    {
        shasum -a 256 "$PIN_FILE" | cut -d' ' -f1
        (cd "$API_HEADERS" && shasum -a 256 *.h | sort)
    } | shasum -a 256 | cut -d' ' -f1
}
PIN_FINGERPRINT="$(fingerprint)"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$PIN_FINGERPRINT" ]]; then
    echo "llama.cpp prefix already provisioned at pin $LLAMA_CPP_RELEASE ($PREFIX)"
    exit 0
fi

echo "=== Provisioning pinned llama.cpp $LLAMA_CPP_RELEASE ==="

# --- Fetch + verify the release asset ----------------------------------------
mkdir -p "$CACHE_DIR"
TARBALL="$CACHE_DIR/$LLAMA_CPP_ASSET"
URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_CPP_RELEASE/$LLAMA_CPP_ASSET"

verify_tarball() {
    [[ -f "$TARBALL" ]] || return 1
    [[ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" == "$LLAMA_CPP_SHA256" ]]
}

if verify_tarball; then
    echo "  $LLAMA_CPP_ASSET (cached, sha256 verified)"
else
    echo "  $LLAMA_CPP_ASSET (downloading ~11 MB)"
    rm -f "$TARBALL"
    curl -fsSL "$URL" -o "$TARBALL" || {
        echo "ERROR: Failed to download $URL" >&2
        echo "  Offline? Point the build at an existing llama.cpp prefix instead:" >&2
        echo "    LOCAL_LLAMA_PREFIX=/opt/homebrew   (whatever version brew has, OFF-PIN)" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
    if [[ "$actual" != "$LLAMA_CPP_SHA256" ]]; then
        echo "ERROR: sha256 mismatch for $LLAMA_CPP_ASSET" >&2
        echo "  expected: $LLAMA_CPP_SHA256" >&2
        echo "  actual:   $actual" >&2
        echo "  GitHub release assets are immutable, so this means the pin is wrong," >&2
        echo "  not that upstream changed. Re-derive LLAMA_CPP_SHA256." >&2
        rm -f "$TARBALL"
        exit 1
    fi
fi

# --- Stage lib/ from the asset ------------------------------------------------
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
tar -xzf "$TARBALL" -C "$WORKDIR"

EXTRACTED="$WORKDIR/llama-$LLAMA_CPP_RELEASE"
if [[ ! -d "$EXTRACTED" ]]; then
    # Upstream has been consistent about this layout; do not guess if it moves.
    echo "ERROR: Expected the asset to unpack to llama-$LLAMA_CPP_RELEASE/" >&2
    echo "  Got: $(find "$WORKDIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;)" >&2
    exit 1
fi

# The asset also carries CLI executables (llama-cli, llama-server, ...), the
# multimodal libmtmd, and the libllama-*-impl.dylib backing those tools. None of
# it is linked by CLlamaBridge, and everything staged here gets embedded into the
# packaged .app, so stage only the closure the bridge needs. The closure check
# below fails closed if that judgement is ever wrong.
echo "=== Staging dylibs ==="
staged=0
for src in "$EXTRACTED"/*.dylib; do
    name="$(basename "$src")"
    case "$name" in
        libllama.dylib | libllama.*.dylib | \
        libllama-common.dylib | libllama-common.*.dylib | \
        libggml.dylib | libggml.*.dylib | \
        libggml-base*.dylib | libggml-cpu*.dylib | \
        libggml-blas*.dylib | libggml-metal*.dylib | libggml-rpc*.dylib)
            # -a preserves the symlink triplets upstream ships
            # (libllama.dylib -> libllama.0.dylib -> libllama.0.0.<rel>.dylib);
            # dereferencing them would triple the prefix size for nothing.
            cp -a "$src" "$PREFIX/lib/"
            staged=$((staged + 1))
            ;;
    esac
done

if [[ "$staged" -eq 0 ]]; then
    echo "ERROR: Staged no dylibs from $EXTRACTED." >&2
    exit 1
fi
echo "  staged $staged dylib entries"

# The versioned filename encodes the build number, so this catches a pin whose
# LLAMA_CPP_ASSET names a different release than LLAMA_CPP_RELEASE.
VERSIONED="libllama.0.0.${LLAMA_CPP_RELEASE#b}.dylib"
if [[ ! -f "$PREFIX/lib/$VERSIONED" ]]; then
    echo "ERROR: Expected $VERSIONED in the asset, but it is not there." >&2
    echo "  LLAMA_CPP_ASSET=$LLAMA_CPP_ASSET does not look like release $LLAMA_CPP_RELEASE." >&2
    exit 1
fi

for required in libllama.dylib libllama-common.dylib libggml.dylib libggml-base.dylib \
    libggml-cpu.dylib libggml-metal.dylib; do
    if [[ ! -e "$PREFIX/lib/$required" ]]; then
        echo "ERROR: Required library missing from the staged prefix: $required" >&2
        exit 1
    fi
done

# --- Verify the @rpath closure is self-contained ------------------------------
# Every @rpath dependency must resolve inside lib/. This is what makes the
# allowlist above safe, and it is the check the abandoned Homebrew-bottle route
# would have failed: there the compute backends were dlopen'd plugins under
# libexec/, so nothing in the Mach-O graph revealed that they were missing and
# the failure only surfaced as "Failed to load llama.cpp model" at runtime.
echo "=== Verifying @rpath closure ==="
missing=0
for f in "$PREFIX"/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        if [[ ! -e "$PREFIX/lib/$(basename "$dep")" ]]; then
            echo "ERROR: $(basename "$f") needs $(basename "$dep"), which is not staged." >&2
            missing=1
        fi
    done < <(otool -L "$f" | awk '/@rpath\// {print $1}')
done
[[ "$missing" -eq 0 ]] || exit 1

# Nothing outside the prefix and the OS may be required — no Homebrew libomp,
# no openssl. This is a property of the upstream release build; assert it so a
# future asset that reintroduces such a dep is caught here rather than by
# package-macos-demo.sh's gate (or by an end user with no Homebrew).
external=0
for f in "$PREFIX"/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    while read -r dep; do
        case "$dep" in
            @rpath/* | /usr/lib/* | /System/*) ;;
            *)
                echo "ERROR: $(basename "$f") depends on $dep, outside the prefix and the OS." >&2
                external=1
                ;;
        esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done
[[ "$external" -eq 0 ]] || exit 1
echo "  closure is self-contained"

# --- Verify the deployment floor ---------------------------------------------
# package-macos-demo.sh fails closed if any embedded Mach-O targets a newer
# macOS than the floor, so catch it here where the fix is a pin change.
FLOOR="${LOCAL_WALLET_DEPLOYMENT_TARGET:-15.0}"
echo "=== Verifying deployment targets (floor $FLOOR) ==="
for f in libllama.dylib libllama-common.dylib libggml.dylib libggml-base.dylib \
    libggml-cpu.dylib libggml-metal.dylib; do
    minos="$(otool -l "$PREFIX/lib/$f" | awk '/LC_BUILD_VERSION/,/sdk/' | awk '/minos/ {print $2; exit}')"
    if [[ -z "$minos" ]]; then
        echo "ERROR: Could not read minos from $f" >&2
        exit 1
    fi
    if [[ "$(printf '%s\n%s\n' "$minos" "$FLOOR" | sort -V | head -1)" != "$minos" ]]; then
        echo "ERROR: $f targets macOS $minos, newer than the $FLOOR floor." >&2
        exit 1
    fi
done
echo "  all staged dylibs target macOS $minos or older"

# --- Stage include/ from the vendored headers --------------------------------
# The release asset ships no headers at all; see
# local-llm/third_party/llama_cpp_api/COMMIT for why they are vendored instead
# of downloaded. Copying them in here keeps exactly one copy of llama.h on the
# compiler's include path and keeps the prefix self-describing.
echo "=== Staging vendored public headers ==="
cp "$API_HEADERS"/*.h "$PREFIX/include/"
echo "  $(find "$PREFIX/include" -name '*.h' | wc -l | tr -d ' ') headers from llama_cpp_api @ ${LLAMA_CPP_COMMIT:0:12}"

echo "$PIN_FINGERPRINT" >"$STAMP"
ln -sfn "$LLAMA_CPP_RELEASE" "$LLAMA_DIR/current"

echo "=== Pinned llama.cpp ready ==="
echo "  prefix: $PREFIX"
echo "  linked: $LLAMA_DIR/current -> $LLAMA_CPP_RELEASE"
echo "  size:   $(du -sh "$PREFIX" | cut -f1)"
