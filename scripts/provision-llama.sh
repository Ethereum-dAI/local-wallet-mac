#!/bin/bash
# Assemble the pinned llama.cpp prefix declared in local-llm/LLAMA_CPP_PIN.
#
# Downloads the pinned upstream release asset from GitHub, verifies it against
# the sha256 in the pin, and assembles a repo-local prefix at .llama/current:
#
#   .llama/<release>/lib            <- dylibs from the release asset
#   .llama/<release>/include        <- llama.cpp + ggml public headers
#   .llama/<release>/include-common <- llama.cpp common/ headers (+ jinja/, nlohmann/)
#
# Headers are fetched from the pinned commit with a sparse, blob-filtered git
# fetch (~1 MB, ~3s) rather than being committed to this repo. Git verifies the
# objects it fetches against the commit SHA, so the SHA in the pin *is* the
# integrity guarantee -- there is no header checksum to maintain and no way for
# the headers to disagree with the pin.
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
SRC_DIR="$CACHE_DIR/llama-src"
UPSTREAM="https://github.com/ggml-org/llama.cpp.git"

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
# Everything is built here first and only swapped into $PREFIX once every step has
# succeeded, so a failure part-way through cannot leave a half-built prefix that
# the build then compiles against.
STAGING="$LLAMA_DIR/.staging-$LLAMA_CPP_RELEASE"

for tool in shasum curl tar otool git; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: Required tool not found: $tool" >&2
        exit 1
    }
done

# The files Package.swift needs. Used to decide whether an existing prefix is
# actually usable, not merely stamped.
prefix_is_complete() {
    local root="$1"
    [[ -e "$root/lib/libllama.dylib" ]] &&
        [[ -f "$root/include/llama.h" ]] &&
        [[ -f "$root/include-common/chat.h" ]]
}

# Point .llama/current at the pinned release. This is the path Package.swift
# consumes, so it -- not the per-release stamp -- is what determines which
# llama.cpp the build actually uses.
repoint_current() {
    ln -sfn "$LLAMA_CPP_RELEASE" "$LLAMA_DIR/current"
}

# --- Fast path: prefix already matches the pin --------------------------------
# The fingerprint is the pin file's hash: it names both the release asset and the
# header commit, so any change to either re-provisions. It deliberately does NOT
# cover the prefix path -- the staged dylibs use @rpath install names, so the
# prefix is relocatable and moving the repo needs a Swift rebuild, not a
# re-provision.
PIN_FINGERPRINT="$(shasum -a 256 "$PIN_FILE" | cut -d' ' -f1)"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$PIN_FINGERPRINT" ]] && prefix_is_complete "$PREFIX"; then
    # The stamp is per-release, so it says nothing about where `current` points.
    # Bumping the pin and then reverting it leaves `current` on the newer release
    # with the older release still stamped: without this the script would report
    # success while the build compiled against a release the repo does not declare.
    if [[ "$(readlink "$LLAMA_DIR/current" 2>/dev/null)" != "$LLAMA_CPP_RELEASE" ]]; then
        repoint_current
        echo "Repointed .llama/current -> $LLAMA_CPP_RELEASE (was stale)"
    fi
    echo "llama.cpp prefix already provisioned at pin $LLAMA_CPP_RELEASE ($PREFIX)"
    exit 0
fi

# A stamped but incomplete prefix means an earlier run died part-way through (or
# somebody deleted files by hand). Re-provision rather than trust the stamp.
if [[ -f "$STAMP" ]] && ! prefix_is_complete "$PREFIX"; then
    echo "Prefix at $PREFIX is stamped but incomplete; re-provisioning."
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
        echo "  Offline or GitHub unreachable. The previously provisioned prefix, if any," >&2
        echo "  is untouched, so an existing checkout keeps building." >&2
        echo "  Note that LOCAL_LLAMA_PREFIX=/opt/homebrew is NOT a way out: Homebrew" >&2
        echo "  ships no llama.cpp common/ headers, so the build would fail on 'chat.h'." >&2
        echo "  An override prefix must provide lib/, include/ and include-common/." >&2
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
rm -rf "$STAGING"
mkdir -p "$STAGING/lib" "$STAGING/include"

WORKDIR="$(mktemp -d)"
# Also clears the staging prefix, so a failed run leaves no half-built directory
# behind. On success the staging dir has already been moved, making this a no-op.
trap 'rm -rf "$WORKDIR" "$STAGING"' EXIT
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
            cp -a "$src" "$STAGING/lib/"
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
if [[ ! -f "$STAGING/lib/$VERSIONED" ]]; then
    echo "ERROR: Expected $VERSIONED in the asset, but it is not there." >&2
    echo "  LLAMA_CPP_ASSET=$LLAMA_CPP_ASSET does not look like release $LLAMA_CPP_RELEASE." >&2
    exit 1
fi

for required in libllama.dylib libllama-common.dylib libggml.dylib libggml-base.dylib \
    libggml-cpu.dylib libggml-metal.dylib; do
    if [[ ! -e "$STAGING/lib/$required" ]]; then
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
for f in "$STAGING"/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        if [[ ! -e "$STAGING/lib/$(basename "$dep")" ]]; then
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
for f in "$STAGING"/lib/*.dylib; do
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
# Every staged dylib, not a hard-coded subset: libggml-blas and libggml-rpc are
# staged too and get pulled into Contents/Frameworks by package-macos-demo.sh's
# recursive embedder, so leaving them unchecked would defer the failure to that
# script's verify_mach_o_deployment_targets gate -- the deferral this check exists
# to prevent.
max_minos=""
for f in "$STAGING"/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/,/sdk/' | awk '/minos/ {print $2; exit}')"
    if [[ -z "$minos" ]]; then
        echo "ERROR: Could not read minos from $(basename "$f")" >&2
        exit 1
    fi
    if [[ "$(printf '%s\n%s\n' "$minos" "$FLOOR" | sort -V | head -1)" != "$minos" ]]; then
        echo "ERROR: $(basename "$f") targets macOS $minos, newer than the $FLOOR floor." >&2
        exit 1
    fi
    # Report the newest requirement across the set, not whichever came last.
    if [[ -z "$max_minos" || "$(printf '%s\n%s\n' "$max_minos" "$minos" | sort -V | tail -1)" == "$minos" ]]; then
        max_minos="$minos"
    fi
done
if [[ -z "$max_minos" ]]; then
    echo "ERROR: No dylibs found to check deployment targets against." >&2
    exit 1
fi
echo "  all staged dylibs target macOS $max_minos or older"

# --- Fetch + stage the headers from the pinned commit -------------------------
# The release asset ships dylibs, CLI executables and LICENSE only -- zero
# headers. Rather than committing upstream's headers to this repo, fetch them at
# the pinned commit: sparse checkout of just the header directories plus
# --filter=blob:none, which is ~1 MB and a few seconds against the 36 MB of a
# full source archive.
#
# Git verifies fetched objects against the commit SHA, so no header checksum is
# needed and the headers cannot drift from the pin -- they *are* the pin's commit.
echo "=== Fetching headers at ${LLAMA_CPP_COMMIT:0:12} ==="

# The release tag is the only thing that ties LLAMA_CPP_COMMIT to the release the
# dylibs were built from. Without this check a commit that merely *exists*
# upstream provisions happily, and the headers would then describe a different
# ABI than the downloaded dylibs -- which, because the mangled C++ symbol names
# do not change across these bumps, is silent runtime corruption rather than a
# link error. So verify the pair against upstream rather than trusting the pin to
# be internally consistent.
resolve_tag_commit() {
    local peeled
    peeled="$(git ls-remote "$UPSTREAM" "refs/tags/$LLAMA_CPP_RELEASE^{}" 2>/dev/null | cut -f1 | head -1)"
    if [[ -n "$peeled" ]]; then
        printf '%s\n' "$peeled"          # annotated tag: the peeled commit
    else
        git ls-remote "$UPSTREAM" "refs/tags/$LLAMA_CPP_RELEASE" 2>/dev/null | cut -f1 | head -1
    fi
}

tag_commit="$(resolve_tag_commit)"
if [[ -z "$tag_commit" ]]; then
    echo "ERROR: Could not resolve tag $LLAMA_CPP_RELEASE upstream." >&2
    echo "  Offline, or LLAMA_CPP_RELEASE does not name a real release." >&2
    exit 1
fi
if [[ "$tag_commit" != "$LLAMA_CPP_COMMIT" ]]; then
    echo "ERROR: LLAMA_CPP_COMMIT is not the commit release $LLAMA_CPP_RELEASE was built from." >&2
    echo "  pin declares:  $LLAMA_CPP_COMMIT" >&2
    echo "  $LLAMA_CPP_RELEASE points at: $tag_commit" >&2
    echo "  The headers would describe a different ABI than the dylibs. Fix the pin:" >&2
    echo "    gh api repos/ggml-org/llama.cpp/git/refs/tags/$LLAMA_CPP_RELEASE --jq '.object.sha'" >&2
    exit 1
fi
echo "  $LLAMA_CPP_RELEASE resolves to the pinned commit"

if [[ ! -d "$SRC_DIR/.git" ]]; then
    mkdir -p "$SRC_DIR"
    git -C "$SRC_DIR" init -q
    git -C "$SRC_DIR" remote add origin "$UPSTREAM"
fi

git -C "$SRC_DIR" config core.sparseCheckout true
git -C "$SRC_DIR" config extensions.partialClone origin
printf 'include/\nggml/include/\ncommon/\nvendor/nlohmann/\n' \
    >"$SRC_DIR/.git/info/sparse-checkout"

if ! git -C "$SRC_DIR" fetch -q --depth 1 --filter=blob:none origin "$LLAMA_CPP_COMMIT"; then
    echo "ERROR: Could not fetch llama.cpp commit $LLAMA_CPP_COMMIT." >&2
    echo "  GitHub unreachable. (A commit that does not exist upstream is rejected" >&2
    echo "  earlier, by the release-tag check.) The previously provisioned prefix," >&2
    echo "  if any, is untouched, so an existing checkout keeps building." >&2
    exit 1
fi
git -C "$SRC_DIR" checkout -q --force FETCH_HEAD

# Assert what git already guaranteed, so a mis-specified pin cannot slip through.
fetched_sha="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [[ "$fetched_sha" != "$LLAMA_CPP_COMMIT" ]]; then
    echo "ERROR: Fetched $fetched_sha but the pin declares $LLAMA_CPP_COMMIT." >&2
    exit 1
fi

# Two include roots, mirroring how the bridge consumes them:
#   include/         <llama.h>, ggml headers      -- the public API
#   include-common/  "chat.h" and friends         -- llama.cpp's common/ layer,
#                                                   whose implementations live in
#                                                   libllama-common.dylib
# nlohmann lands *inside* include-common/ because common/chat.h includes it as
# "nlohmann/json_fwd.hpp", relative to its own directory, while upstream keeps it
# at vendor/nlohmann/ and resolves it via a separate -I.
mkdir -p "$STAGING/include-common/jinja" "$STAGING/include-common/nlohmann"
cp "$SRC_DIR"/include/*.h "$STAGING/include/"
cp "$SRC_DIR"/ggml/include/*.h "$STAGING/include/"
cp "$SRC_DIR"/common/*.h "$STAGING/include-common/"
cp "$SRC_DIR"/common/jinja/*.h "$STAGING/include-common/jinja/"
cp "$SRC_DIR"/vendor/nlohmann/*.hpp "$STAGING/include-common/nlohmann/"

for required in "include/llama.h" "include/ggml.h" "include-common/chat.h" \
    "include-common/common.h" "include-common/jinja/runtime.h" \
    "include-common/nlohmann/json.hpp"; do
    if [[ ! -f "$STAGING/$required" ]]; then
        echo "ERROR: Expected header missing after staging: $required" >&2
        echo "  Upstream may have moved it at $LLAMA_CPP_COMMIT." >&2
        exit 1
    fi
done
echo "  public: $(find "$STAGING/include" -name '*.h' | wc -l | tr -d ' ') headers"
echo "  common: $(find "$STAGING/include-common" -name '*.h' -o -name '*.hpp' | wc -l | tr -d ' ') headers"

echo "$PIN_FINGERPRINT" >"$STAGING/.pin-stamp"

# --- Swap the finished prefix into place --------------------------------------
# Only now is $PREFIX touched. Everything above ran against $STAGING, so a failed
# download, a rejected tag, an unreachable remote or a missing header leaves the
# previously working prefix exactly as it was -- which matters because a partially
# staged prefix is unbuildable and, with the headers no longer vendored, there is
# no in-tree copy to fall back on while offline.
echo "=== Installing ==="
if [[ -d "$PREFIX" ]]; then
    rm -rf "$PREFIX.replaced"
    mv "$PREFIX" "$PREFIX.replaced"
fi
if ! mv "$STAGING" "$PREFIX"; then
    echo "ERROR: Could not move $STAGING into place at $PREFIX." >&2
    if [[ -d "$PREFIX.replaced" ]]; then
        mv "$PREFIX.replaced" "$PREFIX"
        echo "  Restored the previous prefix." >&2
    fi
    exit 1
fi
rm -rf "$PREFIX.replaced"

repoint_current

# --- Prune superseded releases ------------------------------------------------
# Each bump would otherwise leave a full prefix behind (~14 MB) and a stale
# tarball (~11 MB), per worktree. Only the release `current` points at is useful.
pruned=0
for old in "$LLAMA_DIR"/b*; do
    [[ -d "$old" ]] || continue
    [[ "$(basename "$old")" == "$LLAMA_CPP_RELEASE" ]] && continue
    rm -rf "$old"
    pruned=$((pruned + 1))
done
for old_asset in "$CACHE_DIR"/llama-*-bin-macos-arm64.tar.gz; do
    [[ -f "$old_asset" ]] || continue
    [[ "$(basename "$old_asset")" == "$LLAMA_CPP_ASSET" ]] && continue
    rm -f "$old_asset"
    pruned=$((pruned + 1))
done
[[ "$pruned" -gt 0 ]] && echo "  pruned $pruned superseded prefix/asset(s)"

echo "=== Pinned llama.cpp ready ==="
echo "  prefix: $PREFIX"
echo "  linked: $LLAMA_DIR/current -> $LLAMA_CPP_RELEASE"
echo "  size:   $(du -sh "$PREFIX" | cut -f1)"
