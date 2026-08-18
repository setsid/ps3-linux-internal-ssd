#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a Debian-on-PS3 installer stick, from nothing or from wherever you got
# to last time.
#
#   sudo ./scripts/make-debian-installer.sh [options]
#
#   --plain          no cursor addressing, no colour, no progress bars; behaves
#                    exactly as the individual scripts do. Automatic when stdout
#                    is not a terminal, when TERM is dumb, or when NO_COLOR is
#                    set.
#   --kernel DIR     kernel tree            (default ~/ps3-linux, the
#                    invoking user's home, not root's)
#   --rootfs DIR     Debian tree            (default /srv/ps3root)
#   --image FILE     image to build         (default /tmp/ps3root4g.img)
#   --user NAME      user to create in the tree, if it is being built
#   --yes            do not pause before each step
#   --help
#
# This drives README steps 0 to 6 by calling the same scripts those steps call.
# It reimplements none of them: if this tool and the README ever disagree, the
# scripts are the truth and this is the bug.
#
# Everything it runs is echoed and logged unfiltered. The log path is printed at
# the end and on any failure. This project was debugged by reading scrolling
# output, so the output stays on screen.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO/scripts"

# Under sudo $HOME is root's, so the default kernel tree would be /root/ps3-linux
# - a path nobody has. Resolve the invoking user's home instead.
CALLER_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
    _h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    [ -n "$_h" ] && CALLER_HOME="$_h"
fi

KDIR="$CALLER_HOME/ps3-linux"
ROOTFS=/srv/ps3root
IMG=/tmp/ps3root4g.img
BLOCKS=1048576
USERNAME=""
ASSUME_YES=0
FORCE_PLAIN=0
CROSS=powerpc64-linux-gnu-
LOG="/tmp/make-debian-installer-$(date +%Y%m%d-%H%M%S).log"

while [ $# -gt 0 ]; do
    case "$1" in
        --plain)  FORCE_PLAIN=1 ;;
        --kernel) KDIR="$2"; shift ;;
        --rootfs) ROOTFS="$2"; shift ;;
        --image)  IMG="$2"; shift ;;
        --user)   USERNAME="$2"; shift ;;
        --yes|-y) ASSUME_YES=1 ;;
        --help|-h) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

IMG_GZ_NAME="$(basename "$IMG").gz"
SIZE_MIB=$(( BLOCKS * 4096 / 1048576 ))

# ---------------------------------------------------------------- appearance

if [ "$FORCE_PLAIN" = 1 ] || [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ] \
   || [ "${TERM:-dumb}" = dumb ]; then
    UI=plain
else
    UI=fancy
fi

if [ "$UI" = fancy ]; then
    B=$'\033[1m'; N=$'\033[0m'; D=$'\033[2m'
    G=$'\033[32m'; R=$'\033[31m'; C=$'\033[36m'; Y=$'\033[33m'
else
    B=; N=; D=; G=; R=; C=; Y=
fi

# All cursor addressing and progress drawing goes to fd 3, bound to the
# terminal - never to stdout. A function that draws the header while its own
# stdout is being captured by a command substitution would otherwise return the
# escape sequences as part of its value. That is not hypothetical: md5_of() did
# exactly that, and the resulting hash mismatch was reported against two
# identical-looking strings because the difference was invisible escapes.
if [ "$UI" = fancy ] && { exec 3>/dev/tty; } 2>/dev/null; then
    :
else
    exec 3>/dev/null
fi

TROWS=24; TCOLS=80
term_size() {
    local sz
    sz=$(stty size 2>/dev/null) || sz=""
    if [ -n "$sz" ]; then
        TROWS=${sz%% *}; TCOLS=${sz##* }
    fi
    [ "${TROWS:-0}" -ge 12 ] 2>/dev/null || TROWS=24
    [ "${TCOLS:-0}" -ge 40 ] 2>/dev/null || TCOLS=80
}

HDR_LINES=8
PHASE_NUM=0
PHASE_TOTAL=7
PHASE_NAME="starting"
PHASE_WHY=""
PHASE_WHY2=""
PHASE_DETAIL=""
PHASE_LABEL=""
PHASE_CUR=0
PHASE_TOT=0
PHASE_EXTRA=""
START_TS=$(date +%s)

hms() {
    local t=$1
    printf '%02d:%02d:%02d' $((t/3600)) $((t%3600/60)) $((t%60))
}

# The one thing a user watches during a fifteen minute step, so it lives in the
# fixed header rather than scrolling away, and carries the number as well as the
# bar - at a glance a bar alone does not separate 70% from 80%.
progress_line() {
    local w=40 pct filled
    [ -n "$PHASE_LABEL" ] || return 0
    case "${PHASE_CUR}${PHASE_TOT}" in *[!0-9]*) PHASE_TOT=0 ;; esac
    if [ "${PHASE_TOT:-0}" -gt 0 ]; then
        pct=$(( PHASE_CUR * 100 / PHASE_TOT ))
        [ "$pct" -gt 100 ] && pct=100
        filled=$(( pct * w / 100 ))
        printf '  %s%-16s%s %s%s%s%s%s  %s%3d%%%s  %s%s%s' \
            "$B" "$PHASE_LABEL" "$N" \
            "$C" "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$N" \
            "$D" "$(printf '%*s' $((w - filled)) '' | tr ' ' '.')" \
            "$B" "$pct" "$N" \
            "$D" "$PHASE_EXTRA" "$N"
    else
        printf '  %s%-16s%s  %s%s%s' "$B" "$PHASE_LABEL" "$N" \
            "$D" "$PHASE_EXTRA" "$N"
    fi
}

set_progress() { # set_progress <label> <cur> <tot> [extra]
    PHASE_LABEL=$1; PHASE_CUR=$2; PHASE_TOT=$3; PHASE_EXTRA=${4:-}
}

ui_begin() {
    [ "$UI" = fancy ] || return 0
    term_size
    printf '\033[2J\033[H' >&3
    printf '\033[%d;%dr' $((HDR_LINES + 1)) "$TROWS" >&3
    printf '\033[%d;1H' $((HDR_LINES + 1)) >&3
    # Draw the block once before any output scrolls, otherwise the first screen
    # shows the body over an empty header and only settles at the next phase.
    ui_header
}

ui_end() {
    [ "$UI" = fancy ] || return 0
    printf '\033[r' >&3
    printf '\033[%d;1H\033[?25h' "$TROWS" >&3
}
trap 'ui_end' EXIT

# Redraw the fixed block at the top. Leaves the cursor where it found it, so
# the scrolling output below is undisturbed.
ui_header() {
    [ "$UI" = fancy ] || return 0
    local el; el=$(hms $(( $(date +%s) - START_TS )))
    local rule; rule=$(printf '%*s' $((TCOLS > 2 ? TCOLS - 1 : 79)) '' | tr ' ' '-')
    printf '\033[s\033[H' >&3
    printf '%s\033[K\n' "${C}${B}Debian on PS3 - installer${N}" >&3
    printf '%s\033[K\n' "${D}${rule}${N}" >&3
    printf '%s\033[K\n' "${B}Phase ${PHASE_NUM}/${PHASE_TOTAL}: ${PHASE_NAME}${N}   ${D}elapsed ${el}${N}" >&3
    printf '%s\033[K\n' "${PHASE_WHY:0:$((TCOLS - 1))}" >&3
    printf '%s\033[K\n' "${PHASE_WHY2:-}" >&3
    printf '%s\033[K\n' "$(progress_line)" >&3
    printf '%s\033[K\n' "${D}log: ${LOG}${N}" >&3
    printf '%s\033[K\n' "${D}${rule}${N}" >&3
    printf '\033[u' >&3
}

phase() { # phase <n> <name> <why line 1> [why line 2]
    PHASE_NUM=$1; PHASE_NAME=$2; PHASE_WHY=${3:-}; PHASE_WHY2=${4:-}
    PHASE_DETAIL=""; PHASE_LABEL=""; PHASE_CUR=0; PHASE_TOT=0; PHASE_EXTRA=""
    if [ "$UI" = plain ]; then
        echo
        echo "=============================================================="
        echo "Phase $1/$PHASE_TOTAL: $2"
        [ -n "${3:-}" ] && echo "$3"
        [ -n "${4:-}" ] && echo "$4"
        echo "=============================================================="
    else
        ui_header
    fi
    { echo; echo "===== phase $1/$PHASE_TOTAL: $2 ====="; } >> "$LOG"
}

say()  { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG"; }
note() { printf '%s%s%s\n' "$D" "$*" "$N"; printf '%s\n' "$*" >> "$LOG"; }
warn() { printf '%s%s%s\n' "$Y" "$*" "$N"; printf 'WARN: %s\n' "$*" >> "$LOG"; }
fail() {
    printf '%s%sFAILED:%s %s\n' "$R" "$B" "$N" "$*" >&2
    printf 'FAILED: %s\n' "$*" >> "$LOG"
    printf 'Full log: %s\n' "$LOG" >&2
    ui_end
    exit 1
}

# Least privilege. This tool needs root for debootstrap, the chroot work, mount
# and umount, and writing into the rootfs tree - and for nothing else. Run
# everything else as the invoking user, or they are left with a kernel tree of
# thousands of root-owned files they cannot delete, edit or rebuild without
# sudo. Falls back to running directly when invoked as root with no SUDO_USER,
# so the tool still works in that case.
RUN_AS_USER=""
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    RUN_AS_USER="$SUDO_USER"
fi

as_user() {
    if [ -n "$RUN_AS_USER" ]; then
        sudo -u "$RUN_AS_USER" -H "$@"
    else
        "$@"
    fi
}

# Echo the command, run it, mirror its output to screen and log unfiltered.
run() {
    printf '%s$ %s%s\n' "$D" "$*" "$N"
    printf '$ %s\n' "$*" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || fail "$1 exited $rc"
}

# As run(), but dropped to the invoking user. Used for everything that lands in
# the user's own directories.
runu() {
    printf '%s$ %s%s\n' "$D" "$*" "$N"
    printf '$ %s\n' "$*" >> "$LOG"
    as_user "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || fail "$1 exited $rc"
}

# Prefer the controlling terminal so prompts still work when output is piped,
# but fall back to stdin when there is no tty.
ask() { # ask <varname> [prompt]
    local __v=$1
    [ -n "${2:-}" ] && printf '%s' "$2"
    # 2>/dev/null must precede </dev/tty: redirections apply left to right, and
    # a failure to open /dev/tty is reported on whatever stderr is at the time.
    if read -r "$__v" 2>/dev/null </dev/tty; then
        return 0
    fi
    read -r "$__v" || eval "$__v=''"
}

confirm() { # confirm <prompt>
    [ "$ASSUME_YES" = 1 ] && return 0
    local a=""
    ask a "$1 [y/N] "
    case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Poll a running process's read position on stdin. Honest progress: it is the
# actual file offset, not an estimate. Linux only, which covers WSL too.
watch_fd0() { # watch_fd0 <pid> <total-bytes> <label>
    local pid=$1 tot=$2 lbl=$3 pos
    while kill -0 "$pid" 2>/dev/null; do
        pos=$(awk '/^pos:/{print $2; exit}' "/proc/$pid/fdinfo/0" 2>/dev/null)
        [ -n "$pos" ] || pos=0
        set_progress "$lbl" "$pos" "$tot" \
            "$(numfmt --to=iec "$pos" 2>/dev/null || echo "$pos") of $(numfmt --to=iec "$tot" 2>/dev/null || echo "$tot")"
        ui_header
        sleep 0.5
    done
    set_progress "$lbl" "$tot" "$tot" "done"
    ui_header
}

WATCH_PID=""
start_watch() {
    [ "$UI" = fancy ] || return 0   # nothing to draw into
    "$@" & WATCH_PID=$!
}
stop_watch() {
    [ -n "$WATCH_PID" ] || return 0
    kill "$WATCH_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null
    WATCH_PID=""
}

# Count object files against a target. The target is learned from the last
# successful build and corrected upward if this one overshoots, so the bar
# moves and is roughly right rather than precise and wrong.
watch_objs() { # watch_objs <dir> <target>
    local dir=$1 tot=$2 n
    while :; do
        n=$(find "$dir" -name '*.o' 2>/dev/null | wc -l)
        [ "$n" -gt "$tot" ] && tot=$n
        set_progress "compiling" "$n" "$tot" "${n}/${tot} objects"
        ui_header
        sleep 5
    done
}

# Run a command, mirroring output as usual, counting lines that match a shell
# pattern to drive a bar. Used where the command announces its own units of
# work: debootstrap unpacking packages, make installing modules.
run_counted() { # run_counted <label> <total> <pattern> -- cmd...
    local lbl=$1 tot=$2 pat=$3; shift 3
    [ "${1:-}" = -- ] && shift
    printf '%s$ %s%s\n' "$D" "$*" "$N"
    printf '$ %s\n' "$*" >> "$LOG"
    "$@" 2>&1 | { n=0; while IFS= read -r line; do
        printf '%s\n' "$line"
        printf '%s\n' "$line" >> "$LOG"
        case "$line" in
            $pat) n=$((n + 1))
                  set_progress "$lbl" "$n" "$tot" "${n}/${tot}"
                  ui_header ;;
        esac
    done; }
    local rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || fail "$1 exited $rc"
}

# As watch_du, but for a single file that grows - a sparse image being filled.
watch_du_file() { # watch_du_file <file> <total-bytes> <label>
    local f=$1 tot=$2 lbl=$3 cur
    while :; do
        cur=$(du -sB1 "$f" 2>/dev/null | cut -f1)
        [ -n "$cur" ] || cur=0
        set_progress "$lbl" "$cur" "$tot" \
            "$(numfmt --to=iec "$cur" 2>/dev/null || echo "$cur")"
        ui_header
        sleep 2
    done
}

# Poll the size of a growing destination against a known source total.
watch_du() { # watch_du <pid> <dest> <total-bytes> <label>
    local pid=$1 dest=$2 tot=$3 lbl=$4 cur
    while kill -0 "$pid" 2>/dev/null; do
        cur=$(du -sB1 "$dest" 2>/dev/null | cut -f1)
        [ -n "$cur" ] || cur=0
        if [ "$UI" = fancy ]; then
            PHASE_DETAIL="$lbl $(bar "$cur" "$tot")"
            ui_header
        fi
        sleep 1
    done
}

# ------------------------------------------------------------ state detection

kernelrelease() {
    [ -f "$KDIR/.config" ] || return 1
    as_user make -s -C "$KDIR" ARCH=powerpc CROSS_COMPILE="$CROSS" \
        kernelrelease 2>/dev/null
}

newer() { [ -e "$1" ] && [ -e "$2" ] && [ "$1" -nt "$2" ]; }

ST_KTREE=; ST_PATCH=; ST_BUILD=; ST_ROOTFS=; ST_INSTALL=; ST_IMAGE=
KREL=""

detect_state() {
    [ -f "$KDIR/Makefile" ] && ST_KTREE=done || ST_KTREE=missing

    if [ -f "$KDIR/drivers/block/ps3disk.c" ] \
       && grep -q 'ps3disk_find_otheros_region' "$KDIR/drivers/block/ps3disk.c" \
       && grep -q 'offset += bvec.bv_len' "$KDIR/drivers/block/ps3disk.c"; then
        ST_PATCH=done
    elif [ "$ST_KTREE" = done ]; then
        ST_PATCH=missing
    else
        ST_PATCH=blocked
    fi

    if [ -f "$KDIR/vmlinux" ]; then
        if newer "$KDIR/drivers/block/ps3disk.c" "$KDIR/vmlinux"; then
            ST_BUILD=stale
        else
            ST_BUILD=done
        fi
    else
        ST_BUILD=missing
    fi

    [ -d "$ROOTFS/usr/bin" ] && ST_ROOTFS=done || ST_ROOTFS=missing

    KREL=$(kernelrelease) || KREL=""
    ST_INSTALL=missing
    if [ -f "$ROOTFS/boot/vmlinux" ] && [ -f "$ROOTFS/boot/initrd.img" ]; then
        ST_INSTALL=done
        # Stale if the built kernel is newer than what was installed...
        newer "$KDIR/vmlinux" "$ROOTFS/boot/vmlinux" && ST_INSTALL=stale
        # ...or if the initrd predates the kernel it is supposed to match...
        newer "$ROOTFS/boot/vmlinux" "$ROOTFS/boot/initrd.img" && ST_INSTALL=stale
        # ...or if the modules directory is not the one this tree now builds.
        if [ -n "$KREL" ] && [ ! -d "$ROOTFS/lib/modules/$KREL" ]; then
            ST_INSTALL=stale
        fi
    fi

    if [ -f "$IMG" ]; then
        if newer "$ROOTFS/boot/vmlinux" "$IMG"; then
            ST_IMAGE=stale
        else
            ST_IMAGE=done
        fi
    else
        ST_IMAGE=missing
    fi
}

# Anyone who ran an earlier version has a tree full of root-owned files. Say so
# and offer to fix it, rather than failing confusingly later or quietly building
# as root again.
check_ownership() {
    [ -n "$RUN_AS_USER" ] || return 0
    [ -d "$KDIR" ] || return 0
    local stray
    stray=$(find "$KDIR" ! -user "$RUN_AS_USER" -print -quit 2>/dev/null)
    [ -n "$stray" ] || return 0

    echo
    warn "    $KDIR contains files not owned by $RUN_AS_USER."
    warn "    An earlier version of this tool built the kernel as root, so the"
    warn "    tree cannot be deleted, edited or rebuilt without sudo."
    warn "    First one found: $stray"
    echo
    if confirm "    Fix it now with chown -R $RUN_AS_USER on $KDIR?"; then
        run chown -R "$RUN_AS_USER:$(id -gn "$RUN_AS_USER")" "$KDIR"
        say "ownership fixed"
    else
        warn "    Left as is. The build below runs as $RUN_AS_USER and will"
        warn "    fail on any file it cannot write."
    fi
}

mark() {
    case "$1" in
        done)    printf '%s%-6s%s' "$G" "done"  "$N" ;;
        stale)   printf '%s%-6s%s' "$Y" "stale" "$N" ;;
        missing) printf '%s%-6s%s' "$D" "todo"  "$N" ;;
        blocked) printf '%s%-6s%s' "$D" "-"     "$N" ;;
    esac
}

# One dim line when a step is passed over, so the run itself says why nothing
# happened rather than leaving it to the checklist printed minutes earlier.
skip() { printf '    %sskip    %s - already done%s\n' "$D" "$1" "$N"; }

show_state() {
    echo
    echo "    ${B}Where things stand${N}"
    echo
    printf '    %skernel%s\n' "$D" "$N"
    printf '      %s  1. tree at %s\n'      "$(mark $ST_KTREE)"  "$KDIR"
    printf '      %s  2. patches applied\n'  "$(mark $ST_PATCH)"
    printf '      %s  3. built\n'            "$(mark $ST_BUILD)"
    echo
    printf '    %suserland%s\n' "$D" "$N"
    printf '      %s  0. Debian tree at %s\n' "$(mark $ST_ROOTFS)" "$ROOTFS"
    echo
    printf '    %sthen, in order%s\n' "$D" "$N"
    printf '      %s  4. kernel, modules and initrd in the tree\n' "$(mark $ST_INSTALL)"
    printf '      %s  5. image at %s\n'      "$(mark $ST_IMAGE)"  "$IMG"
    printf '      %s  6. stick prepared\n'   "$(mark missing)"
    echo
    [ -n "$KREL" ] && echo "    ${D}kernel release: $KREL${N}"
    if [ "$ST_BUILD" = stale ] || [ "$ST_INSTALL" = stale ] \
       || [ "$ST_IMAGE" = stale ]; then
        echo
        warn "    Something marked stale is older than what it was built from."
        warn "    Rebuilding it is the point - a stale kernel in a fresh image"
        warn "    is the trap that costs a whole write-and-boot cycle to notice."
    fi
    echo
}

pause_for() { # pause_for <what> <how long>
    echo
    echo "${B}Next:${N} $1"
    echo "${D}Expect this to take $2.${N}"
    [ "$ASSUME_YES" = 1 ] && return 0
    confirm "Run it?" || fail "stopped at the user's request"
}

# ------------------------------------------------------------------- the steps

do_ktree() {
    phase 1 "kernel source" \
        "Cloning Geoff Levand's ps3-linux tree. This is the PS3 branch of" \
        "Linux 6.4 - mainline plus the platform support the console needs."
    pause_for "clone the kernel tree into $KDIR" "a few minutes, network bound"
    # --progress: git suppresses its counter when stdout is not a terminal, and
    # here it is a pipe into tee. Its own figures are honest; do not invent any.
    as_user mkdir -p "$(dirname "$KDIR")"
    runu git clone --progress --depth 1 \
        https://git.kernel.org/pub/scm/linux/kernel/git/geoff/ps3-linux.git "$KDIR"
}

do_patch() {
    phase 2 "patches" \
        "Applying the two ps3disk patches: the bounce buffer offset fix, and" \
        "the multi-region patch that exposes every region read-only but one."
    pause_for "patch $KDIR" "seconds"
    runu "$SCRIPTS/kernel-patch.sh" "$KDIR"
}

do_build() {
    phase 3 "kernel build" \
        "Configuring for the PS3 and cross-compiling a big-endian PowerPC" \
        "kernel plus modules. Length depends on core count: $(nproc) here."
    pause_for "configure and build the kernel" \
        "15 minutes or more on $(nproc) cores"
    runu make -C "$KDIR" ARCH=powerpc ps3_defconfig
    runu "$SCRIPTS/kernel-config.sh" "$KDIR"
    local target=1400
    [ -f "$KDIR/.ps3-objcount" ] && target=$(cat "$KDIR/.ps3-objcount")
    start_watch watch_objs "$KDIR" "$target"
    # Bare make: vmlinux alone would skip modules and step 4 would have none.
    runu make -C "$KDIR" ARCH=powerpc CROSS_COMPILE="$CROSS" -j"$(nproc)"
    stop_watch
    find "$KDIR" -name '*.o' 2>/dev/null | wc -l \
        | as_user tee "$KDIR/.ps3-objcount" >/dev/null
    KREL=$(kernelrelease) || KREL=""
    say "kernel release: $KREL"
}

do_rootfs() {
    phase 4 "Debian userland" \
        "debootstrap is unpacking a Debian sid userland for big-endian ppc64" \
        "and running its package scripts under qemu emulation - hence slow."
    # $ROOTFS stays root-owned deliberately. It is a system tree with real
    # uids and modes inside it - setuid binaries, /etc, device nodes - and
    # build-image.sh copies it with cp -a to preserve exactly that. Chowning it
    # to the invoking user would corrupt the image. This is the one place where
    # root ownership is the correct outcome rather than an oversight.
    pause_for "build the Debian tree at $ROOTFS" \
        "about 20 minutes, host speed and emulation bound"
    # debootstrap announces each package as it unpacks. The total is learned
    # from the last successful run; 320 is a starting figure for this set.
    local ptarget=320
    [ -f "$REPO/.ps3-pkgcount" ] && ptarget=$(cat "$REPO/.ps3-pkgcount")
    if [ -n "$USERNAME" ]; then
        run_counted "unpacking" "$ptarget" 'I: *[UE][nx]*ing *' -- \
            "$SCRIPTS/build-rootfs.sh" "$ROOTFS" "$USERNAME"
    else
        say "${Y}build-rootfs.sh will ask for a username and two passwords.${N}"
        say "${Y}Nothing is shipped or defaulted - you set them now.${N}"
        run_counted "unpacking" "$ptarget" 'I: *[UE][nx]*ing *' -- \
            "$SCRIPTS/build-rootfs.sh" "$ROOTFS"
    fi
    ls "$ROOTFS/var/lib/dpkg/info"/*.list 2>/dev/null | wc -l \
        | as_user tee "$REPO/.ps3-pkgcount" >/dev/null
}

do_install() {
    phase 5 "kernel into the tree" \
        "Stripping the kernel, installing modules, and building an initrd to" \
        "match. This is the only place a kernel enters the Debian tree."
    [ -n "$KREL" ] || KREL=$(kernelrelease) || fail "cannot determine kernel release"
    pause_for "install kernel $KREL into $ROOTFS" "a minute or two"
    # strip reads the user's tree and writes /tmp; the copy lands in the rootfs
    # tree, which is root's. See the note on $ROOTFS ownership in do_rootfs().
    runu "${CROSS}strip" -s -o /tmp/vmlinux-stripped "$KDIR/vmlinux"
    run cp /tmp/vmlinux-stripped "$ROOTFS/boot/vmlinux"
    local nko
    nko=$(find "$KDIR" -name '*.ko' 2>/dev/null | wc -l)
    if [ "$nko" -gt 0 ]; then
        run_counted "installing modules" "$nko" '*INSTALL*.ko*' -- \
            make -C "$KDIR" ARCH=powerpc CROSS_COMPILE="$CROSS" \
            INSTALL_MOD_PATH="$ROOTFS" modules_install
    else
        # ps3_defconfig builds almost everything in, so there may be none.
        run make -C "$KDIR" ARCH=powerpc CROSS_COMPILE="$CROSS" \
            INSTALL_MOD_PATH="$ROOTFS" modules_install
    fi
    run cp "$KDIR/.config" "$ROOTFS/boot/config-$KREL"
    run chroot "$ROOTFS" mkinitramfs -o /boot/initrd.img "$KREL"
    [ -f "$ROOTFS/boot/initrd.img" ] || fail "no initrd was produced"
    say "initrd: $(du -h "$ROOTFS/boot/initrd.img" | cut -f1)"
}

do_image() {
    phase 6 "image" \
        "Making an ext4 filesystem and copying the tree into it with cp -a." \
        "The image is what gets written to the console's OtherOS region."
    local tot
    tot=$(du -sB1 "$ROOTFS" 2>/dev/null | cut -f1); [ -n "$tot" ] || tot=0
    pause_for "build $IMG from $ROOTFS ($(numfmt --to=iec "$tot" 2>/dev/null || echo "$tot bytes"))" \
        "a few minutes"
    # build-image.sh mounts the image somewhere private, so watch the blocks
    # actually allocated to the sparse image file instead. Same shape, and it
    # is a real measurement rather than a guess.
    start_watch watch_du_file "$IMG" "$tot" "copying tree"
    run "$SCRIPTS/build-image.sh" "$ROOTFS" "$IMG" "$BLOCKS"
    stop_watch
    # build-image.sh has to run as root - it mounts the image and cp -a needs to
    # preserve the ownership inside the tree - but the file it leaves behind is
    # the user's to delete or copy.
    [ -n "$RUN_AS_USER" ] && chown "$RUN_AS_USER" "$IMG" 2>/dev/null || true
    say "computing md5 of the image"
    IMG_MD5=$(hexonly "$(md5_of "$IMG" "hashing image")")
    say "md5: $IMG_MD5"
}

# Reduce to the hex digits. Belt and braces alongside the fd 3 fix: whatever
# else ends up in the string - escapes, "  -", a stray CR from a file edited on
# Windows - cannot then turn a good copy into a reported mismatch.
hexonly() {
    local h=$1
    h=$(printf '%s' "$h" | tr -cd '0-9a-fA-F')
    printf '%s' "$h" | tr 'A-F' 'a-f'
}

# Hash a known buffer through both paths and assert they agree. Runs at every
# start: the comparison this protects is the one thing standing between the
# user and writing a truncated image, and a verifier that cries wolf on good
# data teaches people to ignore it.
selftest_hash() {
    local t rc=0 direct viaui
    t=$(mktemp); printf 'ps3disk self test\n' > "$t"
    direct=$(hexonly "$(md5sum < "$t" | cut -d" " -f1)")
    viaui=$(hexonly "$(md5_of "$t" "self test")")
    rm -f "$t"
    [ "${#direct}" = 32 ] || rc=1
    [ "$direct" = "$viaui" ] || rc=1
    if [ "$rc" != 0 ]; then
        printf '%s%sself test failed:%s hashing is not comparable\n' "$R" "$B" "$N" >&2
        printf '  direct [%s]\n  via ui [%s]\n' "$direct" "$viaui" >&2
        printf '  refusing to run - a verify pass could not be trusted\n' >&2
        exit 1
    fi
}

md5_of() { # md5_of <file> <label> -> hash on stdout
    local f=$1 lbl=$2 tot out pid
    tot=$(stat -c %s "$f" 2>/dev/null) || tot=0
    out=$(mktemp)
    ( md5sum < "$f" > "$out" ) &
    pid=$!
    watch_fd0 "$pid" "$tot" "$lbl"
    wait "$pid" || { rm -f "$out"; fail "md5 of $f failed"; }
    hexonly "$(cut -d' ' -f1 < "$out")"
    rm -f "$out"
}

# ------------------------------------------------------------- USB selection

IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

# DriveType 2 is removable. Anything else is never returned, so a system disk
# cannot be offered even by accident.
ps_removable() {
    "$1" -NoProfile -Command \
"Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' | ForEach-Object { \
\"\$(\$_.DeviceID)|\$(\$_.VolumeName)|\$(\$_.Size)|\$(\$_.FileSystem)|\$(\$_.FreeSpace)\" }" \
        2>/dev/null | tr -d '\r'
}

# sudo strips WSL's Windows interop entries from PATH, so `command -v
# powershell.exe` finds nothing - and this tool requires sudo, so that is every
# run. Fall back to an absolute path, with the Windows drive root taken from
# /proc/mounts rather than assuming /mnt/c, since WSL can mount elsewhere.
windows_root() {
    local dev mnt fs rest
    while read -r dev mnt fs rest; do
        case "$fs" in 9p|drvfs|drvfs2|v9fs) ;; *) continue ;; esac
        case "$dev" in [A-Za-z]:*) ;; *) continue ;; esac
        case "$dev" in [Cc]:*) printf '%s\n' "$mnt"; return 0 ;; esac
    done < /proc/mounts
    [ -d /mnt/c ] && printf '/mnt/c\n' && return 0
    return 1
}

find_powershell() {
    local p root
    for p in powershell.exe pwsh.exe; do
        p=$(command -v "$p" 2>/dev/null) && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    root=$(windows_root) || return 1
    for p in "$root/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
             "$root/Program Files/PowerShell/7/pwsh.exe"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

STICK_MNT=""
STICK_DESC=""
STICK_CLEANUP=""

cleanup_stick() {
    [ -n "$STICK_CLEANUP" ] || return 0
    umount "$STICK_MNT" 2>/dev/null || true
    rmdir "$STICK_MNT" 2>/dev/null || true
    STICK_CLEANUP=""
}
trap 'cleanup_stick; ui_end' EXIT

# Fills CAND_* arrays. Removable devices only - anything not removable is not
# offered at all, because the failure mode is writing over the wrong disk.
declare -a CAND_ID CAND_LABEL CAND_SIZE CAND_FS CAND_FREE

scan_removable() {
    CAND_ID=(); CAND_LABEL=(); CAND_SIZE=(); CAND_FS=(); CAND_FREE=()
    if [ "$IS_WSL" = 1 ]; then
        local ps out try
        ps=$(find_powershell) || return 1
        # powershell.exe on WSL is slow to come up cold and the first call can
        # return nothing. Retrying is what made it work when pressed twice by
        # hand; do it here instead of leaving the user to guess.
        for try in 1 2 3; do
            out=$(ps_removable "$ps") && [ -n "$out" ] && break
            sleep 2
        done
        # DriveType 2 is removable. Anything else is never listed.
        while IFS='|' read -r id label size fs free; do
            [ -n "$id" ] || continue
            CAND_ID+=("$id"); CAND_LABEL+=("${label:-(no label)}")
            CAND_SIZE+=("${size:-0}"); CAND_FS+=("${fs:-?}")
            CAND_FREE+=("${free:-0}")
        done <<< "$out"
    else
        local name rm size fs label mnt free
        while read -r name rm size fs label mnt; do
            [ "$rm" = 1 ] || continue
            [ -n "$fs" ] || continue
            free=0
            if [ -n "$mnt" ]; then
                free=$(df -B1 --output=avail "$mnt" 2>/dev/null | tail -1 | tr -d ' ')
            fi
            CAND_ID+=("/dev/$name"); CAND_LABEL+=("${label:-(no label)}")
            CAND_SIZE+=("$size"); CAND_FS+=("$fs"); CAND_FREE+=("${free:-0}")
        done < <(lsblk -rno NAME,RM,SIZE,FSTYPE,LABEL,MOUNTPOINT --bytes 2>/dev/null \
                 | awk 'NF>=3')
    fi
    [ "${#CAND_ID[@]}" -gt 0 ]
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

choose_stick() {
    local need=$1 i sel
    while :; do
        if ! scan_removable; then
            if [ "$IS_WSL" = 1 ]; then
                warn "No removable drives found."
                warn "On WSL this needs powershell.exe to tell a USB stick from"
                warn "your system disk. Without it there is no safe way to"
                warn "enumerate, so nothing is offered."
                warn "Looked for it on PATH and under $(windows_root 2>/dev/null || echo '/mnt/c')."
            else
                warn "No removable drives found."
            fi
        else
            echo
            echo "${B}Removable drives${N}   ${D}(only removable devices are listed)${N}"
            echo
            for i in "${!CAND_ID[@]}"; do
                printf '  %d) %-10s %-16s %8s  %-6s free %s\n' \
                    $((i+1)) "${CAND_ID[$i]}" "${CAND_LABEL[$i]}" \
                    "$(human "${CAND_SIZE[$i]}")" "${CAND_FS[$i]}" \
                    "$(human "${CAND_FREE[$i]}")"
            done
        fi
        echo
        ask sel "$(printf '  Select a number, %sr%s to rescan, %sq%s to quit: ' \
            "$B" "$N" "$B" "$N")"
        [ -n "$sel" ] || sel=q
        case "$sel" in
            q|Q) fail "stopped at the user's request" ;;
            r|R) continue ;;
            ''|*[!0-9]*) warn "not a number"; continue ;;
        esac
        i=$((sel - 1))
        [ "$i" -ge 0 ] && [ "$i" -lt "${#CAND_ID[@]}" ] || { warn "out of range"; continue; }
        if [ "${CAND_FREE[$i]}" -gt 0 ] 2>/dev/null \
           && [ "${CAND_FREE[$i]}" -lt "$need" ]; then
            warn "Only $(human "${CAND_FREE[$i]}") free; the image needs $(human "$need")."
            confirm "Pick a different drive?" && continue
            fail "not enough space on the stick"
        fi
        mount_stick "$i" && return 0
    done
}

mount_stick() {
    local i=$1 id="${CAND_ID[$1]}"
    STICK_DESC="$id  ${CAND_LABEL[$i]}  $(human "${CAND_SIZE[$i]}")  ${CAND_FS[$i]}"
    # FAT has no on-disk ownership, so it comes from the mount. Ask for the
    # invoking user's uid, and fall back if the option is rejected, so files
    # written to the stick are theirs to manage afterwards.
    local uidopt=""
    if [ -n "$RUN_AS_USER" ]; then
        uidopt="uid=$(id -u "$RUN_AS_USER"),gid=$(id -g "$RUN_AS_USER")"
    fi

    if [ "$IS_WSL" = 1 ]; then
        STICK_MNT=$(mktemp -d)
        if [ -n "$uidopt" ] && mount -t drvfs -o "$uidopt" "$id" "$STICK_MNT" 2>>"$LOG"; then
            STICK_CLEANUP=1; return 0
        fi
        if mount -t drvfs "$id" "$STICK_MNT" 2>>"$LOG"; then
            STICK_CLEANUP=1; return 0
        fi
        rmdir "$STICK_MNT" 2>/dev/null; warn "could not mount $id"; return 1
    fi
    local mnt
    mnt=$(lsblk -rno MOUNTPOINT "$id" 2>/dev/null | head -1)
    if [ -n "$mnt" ]; then STICK_MNT="$mnt"; return 0; fi
    STICK_MNT=$(mktemp -d)
    if [ -n "$uidopt" ] && mount -o "$uidopt" "$id" "$STICK_MNT" 2>>"$LOG"; then
        STICK_CLEANUP=1; return 0
    fi
    if mount "$id" "$STICK_MNT" 2>>"$LOG"; then STICK_CLEANUP=1; return 0; fi
    rmdir "$STICK_MNT" 2>/dev/null; warn "could not mount $id"; return 1
}

do_stick() {
    phase 7 "the stick" \
        "Compressing the image onto a USB stick with the two console scripts" \
        "and a manifest, so the console side is two commands and no typing."
    local imgsize
    imgsize=$(stat -c %s "$IMG" 2>/dev/null) || fail "no image at $IMG"

    choose_stick "$((imgsize / 3))"

    echo
    echo "${B}Selected:${N} $STICK_DESC"
    echo "${D}mounted at $STICK_MNT${N}"
    echo
    echo "${B}These four files will be written, replacing any of the same name:${N}"
    echo "    $IMG_GZ_NAME"
    echo "    partition-region.sh"
    echo "    write-image.sh"
    echo "    manifest.txt"
    echo
    echo "${B}Nothing else on the stick is touched.${N} Existing folders, homebrew,"
    echo "saves, anything else you keep there is left exactly as it is. This"
    echo "does not format the drive."
    echo
    confirm "Write those four files to $STICK_DESC?" \
        || fail "stopped at the user's request"

    [ -z "${IMG_MD5:-}" ] && IMG_MD5=$(md5_of "$IMG" "hashing image")
    IMG_MD5=$(hexonly "$IMG_MD5")

    # This one stays as root rather than dropping to the user. The stick is
    # FAT, which has no on-disk ownership - it comes from the mount, and
    # mount_stick() asks for the invoking user's uid, so what lands there is
    # already theirs. Running the write as the user instead would fail outright
    # whenever that mount option was rejected, for no gain.
    say "compressing to the stick"
    local dest="$STICK_MNT/$IMG_GZ_NAME" pid
    ( gzip -1 -c < "$IMG" > "$dest" ) &
    pid=$!
    watch_fd0 "$pid" "$imgsize" "gzip to stick"
    wait "$pid" || fail "compressing to the stick failed"

    run cp "$SCRIPTS/partition-region.sh" "$SCRIPTS/write-image.sh" "$STICK_MNT/"

    local mf="$STICK_MNT/manifest.txt"
    cat > "$mf" <<EOF
image=$IMG_GZ_NAME
md5=$IMG_MD5
size_mib=$SIZE_MIB
kernel_release=${KREL:-unknown}
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

    # The no-argument console workflow depends entirely on this file, so read
    # it back and check it parses rather than trusting the redirection.
    [ -s "$mf" ] || fail "manifest.txt is empty or was not written"
    local m_img m_md5 m_mib
    m_img=$(sed -n 's/^image=//p'    "$mf" | head -1)
    m_md5=$(sed -n 's/^md5=//p'      "$mf" | head -1)
    m_mib=$(sed -n 's/^size_mib=//p' "$mf" | head -1)
    [ -n "$m_img" ] || fail "manifest.txt has no image name"
    [ "$m_img" = "$IMG_GZ_NAME" ] \
        || fail "manifest.txt names $m_img, expected $IMG_GZ_NAME"
    [ -e "$STICK_MNT/$m_img" ] \
        || fail "manifest.txt names $m_img, which is not on the stick"
    [ "${#m_md5}" = 32 ] && [ "$(hexonly "$m_md5")" = "$m_md5" ] \
        || fail "manifest.txt md5 is not 32 hex characters: [$m_md5]"
    [ "$m_md5" = "$IMG_MD5" ] \
        || fail "manifest.txt md5 does not match the image"
    case "$m_mib" in ''|*[!0-9]*) fail "manifest.txt size_mib is not a number: [$m_mib]" ;; esac
    say "wrote and verified manifest.txt"

    run sync

    # A bad stick copy otherwise surfaces ten minutes into a write at the
    # console, which is the most expensive place to find it.
    say "verifying the copy on the stick"
    local gzsize check
    gzsize=$(stat -c %s "$dest")
    local out; out=$(mktemp)
    ( gzip -dc < "$dest" | md5sum > "$out" ) &
    pid=$!
    watch_fd0 "$pid" "$gzsize" "verifying stick"
    wait "$pid" || { rm -f "$out"; fail "could not read back the stick copy"; }
    check=$(hexonly "$(cut -d' ' -f1 < "$out")"); rm -f "$out"
    [ "$check" = "$IMG_MD5" ] \
        || fail "stick copy hashes $check, expected $IMG_MD5 - the stick is bad"
    say "${G}stick copy verified${N}"
}

# ------------------------------------------------------------------ main flow

: > "$LOG" || { echo "cannot write $LOG" >&2; exit 1; }
# The user is the one who reads and deletes it.
[ -n "$RUN_AS_USER" ] && chown "$RUN_AS_USER" "$LOG" 2>/dev/null
[ "$(id -u)" = 0 ] || { echo "run with sudo - it writes to $ROOTFS" >&2; exit 1; }

selftest_hash
ui_begin
check_ownership
[ "$UI" = plain ] && say "log: $LOG"
detect_state
show_state

echo "    ${B}What would you like to do?${N}"
echo
echo "      1) Everything outstanding   - run every step not marked done"
echo "      2) Rebuild loop only        - image and stick, from the tree as it is"
echo "      3) A single step"
echo "      q) Quit"
echo
ask CHOICE "      Choice: "
[ -n "$CHOICE" ] || CHOICE=q

case "$CHOICE" in
    1)
        [ "$ST_KTREE" = done ]   && skip "1 kernel tree"    || do_ktree
        [ "$ST_PATCH" = done ]   && skip "2 patches"        || do_patch
        [ "$ST_BUILD" = done ]   && skip "3 kernel build"   || do_build
        [ "$ST_ROOTFS" = done ]  && skip "0 Debian tree"    || do_rootfs
        [ "$ST_INSTALL" = done ] && skip "4 kernel in tree" || do_install
        [ "$ST_IMAGE" = done ]   && skip "5 image"          || do_image
        do_stick
        ;;
    2)
        [ "$ST_ROOTFS" = done ] || fail "no tree at $ROOTFS - use option 1"
        [ "$ST_INSTALL" = done ] || fail "no kernel in the tree - use option 1"
        do_image
        do_stick
        ;;
    3)
        echo
        echo "      1 kernel tree        2 patches   3 kernel build"
        echo "      0 Debian tree        4 kernel into tree"
        echo "      5 image              6 stick"
        ask S "      Step: "
        [ -n "$S" ] || S=q
        case "$S" in
            1) do_ktree ;; 2) do_patch ;; 3) do_build ;; 0) do_rootfs ;;
            4) do_install ;; 5) do_image ;; 6) do_stick ;;
            *) fail "no such step" ;;
        esac
        ;;
    *) ui_end; echo "nothing done"; exit 0 ;;
esac

# ------------------------------------------------------------------- the end

PHASE_NAME="finished"; PHASE_LABEL=""; PHASE_EXTRA=""; ui_header
ui_end

echo
echo "${G}${B}The stick is ready.${N}"
[ -n "$STICK_DESC" ] && echo "$STICK_DESC"
echo
echo "${C}At the console${N}"
echo
echo "  Put the stick in the ${B}rightmost USB port on the front${N} of the"
echo "  console. That gives sda1 consistently on a CECH-2503B."
echo
echo "  At the petitboot shell:"
echo
echo "    ${B}sh /tmp/petitboot/mnt/sda1/partition-region.sh${N}   ${D}# first time only${N}"
echo "    ${B}sh /tmp/petitboot/mnt/sda1/write-image.sh${N}"
echo
echo "  Both scripts stop on failure and say why. A good partition run ends"
echo "  with ${B}ps3swap label confirmed${N}, and a good write ends with"
echo "  ${B}write complete and verified${N}. Anything else, read the log on the"
echo "  stick before going on."
echo
echo "  write-image.sh takes no arguments - it reads manifest.txt from the"
echo "  stick for the hash, image name and size, so there is nothing to type."
echo "  The manifest also tells you a week later which build is on the stick."
echo
echo "  Then reboot and choose ${B}debian${N} - the first entry."
echo "  ${B}Not debian-failsafe${N}, which exists only for the case where the"
echo "  first entry drops you at an initramfs prompt."
echo
echo "  SSH is enabled and the machine takes a DHCP address as eth0. First"
echo "  boot is slow: 256 MB of RAM doing first-boot service setup."
echo
echo "  ${D}The console side takes about 15 minutes: partition, write, verify,${N}"
echo "  ${D}reboot.${N}"
echo
echo "${D}Full log: $LOG${N}"
