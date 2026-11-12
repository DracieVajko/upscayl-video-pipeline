#!/usr/bin/env bash
# Upscayl Video Pipeline V2 - native Unix implementation.
# Requires bash 3.2+, FFmpeg/ffprobe, and Upscayl's CLI.
# No Python, Node, or jq.

# No `set -u`: bash 3.2 fails on empty array expansions under nounset.
UVP_VERSION="0.3.4"
UVP_PROGRAM="upscayl-video"
UVP_TOOL_DIR=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P)
UVP_LOG_FILE=""
UVP_VERBOSE=0
UVP_QUIET=0
HAS_CYGPATH=0
if command -v cygpath >/dev/null 2>&1; then HAS_CYGPATH=1; fi
# Create the scratch directory before any command substitution. A lazy
# creation inside $(...) would run the EXIT trap in the subshell and delete the
# file before the caller can use it.
UVP_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/uvp.XXXXXX") || {
    printf 'Could not create a temporary directory\n' >&2
    exit 1
}
trap 'rm -rf "$UVP_TMP_DIR"' EXIT

# Load the implementation modules in dependency order.
UVP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib"

# shellcheck source=lib/core.sh
. "$UVP_LIB_DIR/core.sh"
# shellcheck source=lib/paths.sh
. "$UVP_LIB_DIR/paths.sh"
# shellcheck source=lib/config.sh
. "$UVP_LIB_DIR/config.sh"
# shellcheck source=lib/media.sh
. "$UVP_LIB_DIR/media.sh"
# shellcheck source=lib/jobs.sh
. "$UVP_LIB_DIR/jobs.sh"
# shellcheck source=lib/frames.sh
. "$UVP_LIB_DIR/frames.sh"
# shellcheck source=lib/split.sh
. "$UVP_LIB_DIR/split.sh"
# shellcheck source=lib/encode.sh
. "$UVP_LIB_DIR/encode.sh"
# shellcheck source=lib/assemble.sh
. "$UVP_LIB_DIR/assemble.sh"
# shellcheck source=lib/upscayl.sh
. "$UVP_LIB_DIR/upscayl.sh"
# shellcheck source=lib/chunking.sh
. "$UVP_LIB_DIR/chunking.sh"
# shellcheck source=lib/run.sh
. "$UVP_LIB_DIR/run.sh"
# shellcheck source=lib/admin.sh
. "$UVP_LIB_DIR/admin.sh"
# shellcheck source=lib/doctor.sh
. "$UVP_LIB_DIR/doctor.sh"
# shellcheck source=lib/menu.sh
. "$UVP_LIB_DIR/menu.sh"
# shellcheck source=lib/cli.sh
. "$UVP_LIB_DIR/cli.sh"

if [ "${UPSCAYL_V2_LIB:-0}" != "1" ]; then
    main "$@"
fi
