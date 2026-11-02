#!/bin/bash
#
# owrx-dab-fix.sh - fixes silent DAB audio in OpenWebRX+ with DABlin >= 1.16
#
# Since DABlin 1.16.0 ("Audio: harmonize output format to 16bit",
# Opendigitalradio/dablin@ba5c3e4), "dablin -p" outputs signed 16-bit PCM.
# OpenWebRX+ still expects float32, so DAB locks and shows the service list,
# but the audio is silent.
#
# This script installs a small s16 -> float32 converter and patches the
# DablinModule of the installed OpenWebRX+ to pipe dablin through it.
# It does not modify anything else. Run with --revert to undo.
#
# Usage: sudo ./owrx-dab-fix.sh [--apply|--revert|--status|--install-hook|--remove-hook] [--force] [--no-restart]
#
# License: MIT

set -euo pipefail

FIX_DIR="/usr/local/lib/owrx-dab-fix"
CONVERTER="$FIX_DIR/dablin_s16tof32.py"
SELF_COPY="$FIX_DIR/owrx-dab-fix.sh"
HOOK_FILE="${HOOK_FILE:-/etc/apt/apt.conf.d/99owrx-dab-fix}"
MARKER="owrx-dab-fix"
BACKUP_SUFFIX=".orig-owrx-dab-fix"
PYTHON="${PYTHON:-/usr/bin/python3}"

ACTION="apply"
FORCE=0
RESTART=1
QUIET=0

log()  { [ "$QUIET" -eq 1 ] || echo "[owrx-dab-fix] $*"; }
warn() { echo "[owrx-dab-fix] WARNING: $*" >&2; }
die()  { echo "[owrx-dab-fix] ERROR: $*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --apply) ACTION="apply" ;;
        --revert) ACTION="revert" ;;
        --status) ACTION="status" ;;
        --install-hook) ACTION="install-hook" ;;
        --remove-hook) ACTION="remove-hook" ;;
        --force) FORCE=1 ;;
        --no-restart) RESTART=0 ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg (see --help)" ;;
    esac
done

# --- locate the installed toolbox.py without importing it (needs no pycsdr) ---
find_toolbox() {
    if [ -n "${OWRX_TOOLBOX:-}" ]; then echo "$OWRX_TOOLBOX"; return; fi
    "$PYTHON" - <<'EOF'
import os, sys
for p in sys.path:
    f = os.path.join(p or ".", "csdr", "module", "toolbox.py")
    if os.path.isfile(f):
        print(os.path.realpath(f))
        break
EOF
}

# --- returns "major minor" of the installed dablin, empty if unknown ---
dablin_version() {
    command -v dablin >/dev/null 2>&1 || return 0
    { dablin -h 2>&1 || true; } | sed -n 's/.*DABlin v\([0-9]\+\)\.\([0-9]\+\).*/\1 \2/p' | head -n1
}

is_patched() { grep -q "$MARKER" "$1"; }

restart_owrx() {
    [ "$RESTART" -eq 1 ] || return 0
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet openwebrx 2>/dev/null; then
        log "restarting openwebrx ..."
        systemctl restart openwebrx
    else
        log "openwebrx service not active - restart OpenWebRX+ yourself."
    fi
}

install_converter() {
    mkdir -p "$FIX_DIR"
    cat > "$CONVERTER" <<'EOF'
#!/usr/bin/env python3
# Part of owrx-dab-fix: converts signed 16-bit PCM (DABlin >= 1.16) to float32.
import sys
import array


def main():
    reader = sys.stdin.buffer
    writer = sys.stdout.buffer
    remainder = b""
    try:
        while True:
            data = reader.read1(8192)
            if not data:
                break
            data = remainder + data
            cut = len(data) - (len(data) % 2)
            remainder = data[cut:]
            samples = array.array("h", data[:cut])
            writer.write(array.array("f", [s / 32768.0 for s in samples]).tobytes())
            writer.flush()
    except (BrokenPipeError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
EOF
    chmod 755 "$CONVERTER"
    # keep a copy of this script for the optional apt hook
    if [ "$(realpath "$0")" != "$SELF_COPY" ]; then
        cp "$0" "$SELF_COPY"
        chmod 755 "$SELF_COPY"
    fi
}

# --- patch the _buildArgs() return line inside DablinModule ---
patch_toolbox() {
    local tb="$1"
    TB="$tb" CONV="$CONVERTER" PY="$PYTHON" MARK="$MARKER" "$PYTHON" - <<'EOF' || return $?
import os, re, sys
tb, conv, py, mark = os.environ["TB"], os.environ["CONV"], os.environ["PY"], os.environ["MARK"]
src = open(tb).read()

start = src.find("class DablinModule(")
if start < 0:
    sys.exit("DablinModule not found in " + tb)
end = src.find("\nclass ", start + 1)
end = len(src) if end < 0 else end
block = src[start:end]

if "Format.FLOAT" not in block:
    sys.exit(2)  # OpenWebRX+ no longer expects float32 - probably fixed upstream

pattern = re.compile(r'^([ \t]*)return \[[^\n]*dablin[^\n]*\][ \t]*$', re.M)
m = pattern.search(block)
if not m:
    sys.exit("could not find the dablin command line in DablinModule._buildArgs()")

indent = m.group(1)
new = ('{i}return ["sh", "-c", "dablin -p -s {{:#06x}} | {py} -u {conv}"'
       '.format(self.serviceId)]  # {mark}').format(i=indent, py=py, conv=conv, mark=mark)
block = block[:m.start()] + new + block[m.end():]
open(tb, "w").write(src[:start] + block + src[end:])
EOF
    "$PYTHON" -m py_compile "$tb" || return 1
}

do_apply() {
    [ "$(id -u)" -eq 0 ] || die "please run as root (sudo)"
    local tb ver
    tb="$(find_toolbox)"
    [ -n "$tb" ] && [ -f "$tb" ] || die "OpenWebRX+ (csdr/module/toolbox.py) not found"
    log "OpenWebRX+ module: $tb"

    if is_patched "$tb"; then
        log "already patched - nothing to do."
        return 0
    fi

    ver="$(dablin_version)"
    if [ -z "$ver" ]; then
        [ "$FORCE" -eq 1 ] || die "dablin not found or version unknown (use --force to patch anyway)"
        warn "dablin version unknown, patching anyway (--force)"
    else
        set -- $ver
        log "DABlin version: $1.$2"
        if [ "$1" -lt 1 ] || { [ "$1" -eq 1 ] && [ "$2" -lt 16 ]; }; then
            [ "$FORCE" -eq 1 ] || { log "DABlin < 1.16 outputs float32 - fix not needed."; return 0; }
        fi
    fi

    install_converter
    cp -p "$tb" "$tb$BACKUP_SUFFIX"
    local rc=0
    patch_toolbox "$tb" || rc=$?
    if [ "$rc" -eq 2 ]; then
        rm -f "$tb$BACKUP_SUFFIX"
        log "DablinModule no longer expects float32 - OpenWebRX+ seems to be fixed upstream, not patching."
        return 0
    elif [ "$rc" -ne 0 ]; then
        cp -p "$tb$BACKUP_SUFFIX" "$tb"
        rm -f "$tb$BACKUP_SUFFIX"
        die "patching failed, toolbox.py left unchanged"
    fi
    log "patched. Backup: $tb$BACKUP_SUFFIX"
    restart_owrx
}

do_revert() {
    [ "$(id -u)" -eq 0 ] || die "please run as root (sudo)"
    local tb
    tb="$(find_toolbox)"
    [ -n "$tb" ] && [ -f "$tb" ] || die "OpenWebRX+ (csdr/module/toolbox.py) not found"
    if ! is_patched "$tb"; then
        log "toolbox.py is not patched."
    elif [ -f "$tb$BACKUP_SUFFIX" ]; then
        cp -p "$tb$BACKUP_SUFFIX" "$tb"
        rm -f "$tb$BACKUP_SUFFIX"
        log "restored original toolbox.py"
        restart_owrx
    else
        die "backup $tb$BACKUP_SUFFIX missing - reinstall the openwebrx package to restore"
    fi
}

do_status() {
    local tb ver
    tb="$(find_toolbox)"
    ver="$(dablin_version)"
    echo "toolbox.py : ${tb:-not found}"
    if [ -n "$ver" ]; then echo "DABlin     : ${ver/ /.}"; else echo "DABlin     : not found"; fi
    if [ -n "$tb" ] && is_patched "$tb"; then echo "patch      : applied"; else echo "patch      : not applied"; fi
    [ -f "$CONVERTER" ] && echo "converter  : $CONVERTER" || echo "converter  : not installed"
    [ -f "$HOOK_FILE" ] && echo "apt hook   : installed" || echo "apt hook   : not installed"
}

do_install_hook() {
    [ "$(id -u)" -eq 0 ] || die "please run as root (sudo)"
    install_converter
    cat > "$HOOK_FILE" <<EOF
// owrx-dab-fix: re-apply the DAB fix after OpenWebRX+ package updates
DPkg::Post-Invoke { "if [ -x $SELF_COPY ]; then $SELF_COPY --apply --quiet || true; fi"; };
EOF
    log "apt hook installed: $HOOK_FILE"
    do_apply
}

do_remove_hook() {
    [ "$(id -u)" -eq 0 ] || die "please run as root (sudo)"
    rm -f "$HOOK_FILE"
    log "apt hook removed."
}

case "$ACTION" in
    apply) do_apply ;;
    revert) do_revert ;;
    status) do_status ;;
    install-hook) do_install_hook ;;
    remove-hook) do_remove_hook ;;
esac
