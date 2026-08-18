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

TROWS=24; TCOLS=80; CLOCK_COL=64
term_size() {
    local sz
    # From the terminal rather than stdin. The painter below runs in the
    # background, where stdin is /dev/null and stty reports nothing, and it is
    # the process that most needs the real width.
    sz=$(stty size < /dev/tty 2>/dev/null) || sz=""
    if [ -n "$sz" ]; then
        TROWS=${sz%% *}; TCOLS=${sz##* }
    fi
    [ "${TROWS:-0}" -ge 12 ] 2>/dev/null || TROWS=24
    [ "${TCOLS:-0}" -ge 40 ] 2>/dev/null || TCOLS=80
    CLOCK_COL=$(( TCOLS - 16 )); [ "$CLOCK_COL" -lt 24 ] && CLOCK_COL=24
    return 0
}

# Header state lives in files, not shell variables, because the processes that
# produce it are not the process that draws it: every watcher is a background
# job with its own copy of the shell's memory, so a bar set in one was invisible
# to the next and the two drew over each other in the same fixed row. One
# painter process owns the terminal and renders whatever state it finds. That
# also gets the elapsed clock ticking, since the painter redraws whether or not
# anything else has produced output.
UIDIR=""
BAR_SLOT=""
HDR_BASE=7                  # title, rule, phase, why, why2, log, rule
HDR_LINES=8                 # base, plus one bar line always reserved
LAST_ROWS=""
PHASE_TOTAL=7
START_TS=$(date +%s)

ui_state() { # ui_state <name> <value...>
    [ -n "$UIDIR" ] || return 0
    local f=$1; shift
    printf '%s\n' "$*" > "$UIDIR/$f" 2>/dev/null || true
}
ui_get() { cat "$UIDIR/$1" 2>/dev/null || true; }

# A bar is a file. Anything that wants one takes a slot and writes to it; the
# painter draws a line per slot it finds, so bars no longer share a row.
bar_alloc() {
    [ -n "$UIDIR" ] || return 0
    mktemp "$UIDIR/bar.XXXXXX" 2>/dev/null || true
}
bar_free() { [ -n "${1:-}" ] && rm -f "$1" 2>/dev/null; return 0; }

hms() {
    local t=$1
    printf '%02d:%02d:%02d' $((t/3600)) $((t%3600/60)) $((t%60))
}

# The one thing a user watches during a fifteen minute step, so it lives in the
# fixed header rather than scrolling away, and carries the number as well as the
# bar - at a glance a bar alone does not separate 70% from 80%.
bar_line() { # bar_line <slot-file>
    local lbl cur tot extra w pct filled
    IFS=$'\t' read -r lbl cur tot extra < "$1" 2>/dev/null || return 0
    [ -n "${lbl:-}" ] || return 0
    case "${cur:-x}${tot:-x}" in *[!0-9]*) cur=0; tot=0 ;; esac
    # Size the bar to the window instead of a fixed 40 columns, or a narrow
    # terminal wraps the header into the scrolling region below it and the two
    # start overwriting each other. Below 64 columns the trailing detail goes
    # first, since the bar and the percentage are what is being watched.
    w=$(( TCOLS - 46 )); [ "$w" -gt 40 ] && w=40; [ "$w" -lt 8 ] && w=8
    [ "$TCOLS" -lt 64 ] && extra=""
    if [ "${tot:-0}" -gt 0 ]; then
        pct=$(( cur * 100 / tot )); [ "$pct" -gt 100 ] && pct=100
        filled=$(( pct * w / 100 ))
        printf '  %s%-16s%s %s%s%s%s%s %s%3d%%%s %s%s%s' \
            "$B" "${lbl:0:16}" "$N" \
            "$C" "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$N" \
            "$D" "$(printf '%*s' $((w - filled)) '' | tr ' ' '.')" \
            "$B" "$pct" "$N" \
            "$D" "${extra:0:18}" "$N"
    else
        printf '  %s%-16s%s %s%s%s' "$B" "${lbl:0:16}" "$N" \
            "$D" "${extra:0:18}" "$N"
    fi
}

set_progress() { # set_progress <label> <cur> <tot> [extra]
    [ -n "$BAR_SLOT" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" > "$BAR_SLOT" 2>/dev/null || true
}

PAINT_PID=""
ui_begin() {
    [ "$UI" = fancy ] || return 0
    term_size
    printf '\033[2J\033[H' >&3
    printf '\033[%d;%dr' $((HDR_LINES + 1)) "$TROWS" >&3
    printf '\033[%d;1H' $((HDR_LINES + 1)) >&3
    # Draw the block once before any output scrolls, otherwise the first screen
    # shows the body over an empty header and only settles at the next phase.
    ui_render
    # From here one painter owns the header, twice a second. It is the only
    # writer that saves and restores the cursor, so there is no race over the
    # terminal's single save slot, and it re-reads the window size every pass,
    # which is what makes a mid-run resize settle by itself.
    ( while :; do ui_render; sleep 0.5; done ) & PAINT_PID=$!
}

ui_end() {
    [ "$UI" = fancy ] || return 0
    if [ -n "$PAINT_PID" ]; then
        kill "$PAINT_PID" 2>/dev/null
        wait "$PAINT_PID" 2>/dev/null
        PAINT_PID=""
    fi
    printf '\033[r' >&3
    printf '\033[%d;1H\033[?25h' "$TROWS" >&3
}
trap 'stop_all_watches; ui_end; ui_cleanup; hand_over_all' EXIT

# Redraw the fixed block at the top. Leaves the cursor where it found it, so
# the scrolling output below is undisturbed. Height follows the number of live
# bars, with one line always reserved so the ordinary single-bar case never
# moves the scroll region.
ui_render() {
    [ "$UI" = fancy ] || return 0
    local el rule f nb want
    term_size
    el=$(hms $(( $(date +%s) - START_TS )))
    rule=$(printf '%*s' $((TCOLS > 2 ? TCOLS - 1 : 79)) '' | tr ' ' '-')

    local slots=()
    if [ -n "$UIDIR" ]; then
        for f in "$UIDIR"/bar.*; do [ -f "$f" ] && slots+=("$f"); done
    fi
    nb=${#slots[@]}; [ "$nb" -lt 1 ] && nb=1
    want=$(( HDR_BASE + nb ))
    if [ "$want" != "$HDR_LINES" ] || [ "$TROWS" != "$LAST_ROWS" ]; then
        local old=$HDR_LINES r grow=0
        HDR_LINES=$want; LAST_ROWS=$TROWS
        # Setting the scroll region homes the cursor, so all of this is bracketed
        # by save and restore. Without that the body resumes writing from line 1,
        # underneath the header, and is painted over half a second later - the
        # output simply disappears.
        printf '\033[s' >&3
        if [ "$want" -gt "$old" ]; then
            # Make room before taking it: insert the difference at the top of the
            # body region so what is on screen moves down, and follow the body's
            # cursor down by the same amount once the region is set.
            grow=$((want - old))
            printf '\033[%d;%dr' $((old + 1)) "$TROWS" >&3
            printf '\033[%d;1H\033[%dL' $((old + 1)) "$grow" >&3
        elif [ "$want" -lt "$old" ]; then
            # Giving rows back: wipe them, or the last bar drawn stays on screen
            # below the now shorter header.
            for (( r = want + 1; r <= old; r++ )); do
                printf '\033[%d;1H\033[K' "$r" >&3
            done
        fi
        printf '\033[%d;%dr' $((HDR_LINES + 1)) "$TROWS" >&3
        printf '\033[u' >&3
        [ "$grow" -gt 0 ] && printf '\033[%dB' "$grow" >&3
    fi

    printf '\033[s\033[H' >&3
    printf '%s\033[K\n' "${C}${B}Debian on PS3 - installer${N}" >&3
    printf '%s\033[K\n' "${D}${rule}${N}" >&3
    # The phase line is written first and the clock dropped onto it at a fixed
    # column. Truncate the name to stop it running into the clock; truncate the
    # why lines to the width, or they wrap into the scrolling region and the
    # header and the output below start overwriting each other.
    local nm; nm="Phase $(ui_get phasenum)/${PHASE_TOTAL}: $(ui_get name)"
    printf '%s\033[K' "${B}${nm:0:$((CLOCK_COL - 2))}${N}" >&3
    printf '\033[3;%dH%selapsed %s%s' "$CLOCK_COL" "$D" "$el" "$N" >&3
    printf '\033[4;1H' >&3
    local w1 w2; w1=$(ui_get why); w2=$(ui_get why2)
    printf '%s\033[K\n' "${w1:0:$((TCOLS - 1))}" >&3
    printf '%s\033[K\n' "${w2:0:$((TCOLS - 1))}" >&3
    if [ "${#slots[@]}" -gt 0 ]; then
        for f in "${slots[@]}"; do printf '%s\033[K\n' "$(bar_line "$f")" >&3; done
    else
        printf '\033[K\n' >&3
    fi
    local lg; lg="log: ${LOG}"
    printf '%s\033[K\n' "${D}${lg:0:$((TCOLS - 1))}${N}" >&3
    printf '%s\033[K\n' "${D}${rule}${N}" >&3
    printf '\033[u' >&3
}

# The watchers still call this after set_progress. The painter is what draws
# now, so it only has to not be an error.
ui_header() { :; }

phase() { # phase <n> <name> <why line 1> [why line 2]
    ui_state phasenum "$1"; ui_state name "$2"
    ui_state why "${3:-}"; ui_state why2 "${4:-}"
    # A new phase owns the header. Any watcher still running belongs to the step
    # that just finished, so stop it before dropping the bars - killing the
    # writer first, or it simply recreates its slot file on the next tick.
    stop_all_watches
    [ -n "$UIDIR" ] && rm -f "$UIDIR"/bar.* 2>/dev/null
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

# Ownership is handed over at the end of the run, not up front, and this is
# load-bearing rather than tidiness.
#
# /tmp is sticky and world-writable, and with fs.protected_regular set - 2 on
# most current kernels - the kernel refuses an O_CREAT open of a file owned by
# neither the opener nor the directory. Root is not exempt: may_create_in_sticky()
# in fs/namei.c has no CAP_DAC_OVERRIDE escape, and bash's >> passes O_CREAT.
# So chowning the log to the invoking user while the run is still going makes it
# unwritable by the root half of this script, which is most of it, and the whole
# 90 minute build records nothing. That is the one output worth keeping when
# something goes wrong, so root keeps ownership until there is nothing left to
# write.
#
# From the EXIT trap, so it happens on failure and on interrupt too.
hand_over() { # hand_over <path>...
    [ -n "${RUN_AS_USER:-}" ] || return 0
    local p grp
    grp=$(id -gn "$RUN_AS_USER" 2>/dev/null) || grp="$RUN_AS_USER"
    for p in "$@"; do
        [ -e "$p" ] || continue
        chown "$RUN_AS_USER:$grp" "$p" 2>/dev/null || true
    done
}

hand_over_all() { hand_over "${LOG:-}" "${IMG:-}"; }

# The other half. A file handed over by a previous run is owned by the user, so
# root cannot reopen it here either - take it back before rewriting it.
reclaim() { # reclaim <path>...
    local p
    for p in "$@"; do
        [ -e "$p" ] || continue
        chown 0:0 "$p" 2>/dev/null || true
    done
}

# Write one of the learned-count files as the invoking user. Unlink first: an
# earlier root-owned run may have left one the user cannot overwrite. They only
# size a progress bar, so a stale count is not worth failing the run over.
put_count() { # put_count <file>   (value on stdin)
    rm -f "$1" 2>/dev/null || true
    as_user tee "$1" >/dev/null 2>&1 || true
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

# For a step that asks the user questions. Two differences from run(). Stdin is
# bound to the terminal explicitly rather than inherited, so it does not matter
# what the tool itself was started with. And the output goes through tee rather
# than the line counter in run_counted: tee passes a partial line straight
# through, whereas a "while read line" loop holds it until a newline arrives, so
# a prompt written without one appears only after the answer was due. That is
# how "username to create: " and the error that followed it ended up on the same
# line. build-rootfs.sh is the only step that needs this - it asks for a
# username, then runs passwd twice and adduser.
runi() {
    printf '%s$ %s%s\n' "$D" "$*" "$N"
    printf '$ %s\n' "$*" >> "$LOG"
    if [ -r /dev/tty ]; then
        "$@" < /dev/tty 2>&1 | tee -a "$LOG"
    else
        "$@" 2>&1 | tee -a "$LOG"
    fi
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
    local pid=$1 tot=$2 lbl=$3 pos own=""
    # Unlike the others this runs in the foreground, so it has no slot handed to
    # it by start_watch and takes one for itself.
    if [ -z "$BAR_SLOT" ]; then BAR_SLOT=$(bar_alloc); own=$BAR_SLOT; fi
    while kill -0 "$pid" 2>/dev/null; do
        pos=$(awk '/^pos:/{print $2; exit}' "/proc/$pid/fdinfo/0" 2>/dev/null)
        [ -n "$pos" ] || pos=0
        set_progress "$lbl" "$pos" "$tot" \
            "$(numfmt --to=iec "$pos" 2>/dev/null || echo "$pos") of $(numfmt --to=iec "$tot" 2>/dev/null || echo "$tot")"
        ui_header
        sleep 0.5
    done
    set_progress "$lbl" "$tot" "$tot" "done"
    [ -n "$own" ] && { bar_free "$own"; BAR_SLOT=""; }
    return 0
}

# More than one watcher can be live, and each gets its own bar line. The single
# WATCH_PID this replaces lost the first pid whenever a second watcher started,
# which left it running and drawing over whatever came next.
WATCH_PIDS=()
WATCH_SLOTS=()
start_watch() {
    [ "$UI" = fancy ] || return 0   # nothing to draw into
    local slot; slot=$(bar_alloc)
    ( BAR_SLOT="$slot"; "$@" ) &
    WATCH_PIDS+=("$!"); WATCH_SLOTS+=("$slot")
}
# Stops the most recent watcher and takes its line back, so the header shrinks.
stop_watch() {
    local n=${#WATCH_PIDS[@]} i
    [ "$n" -gt 0 ] || return 0
    i=$((n - 1))
    kill "${WATCH_PIDS[$i]}" 2>/dev/null
    wait "${WATCH_PIDS[$i]}" 2>/dev/null
    bar_free "${WATCH_SLOTS[$i]}"
    unset "WATCH_PIDS[$i]" "WATCH_SLOTS[$i]"
    return 0
}
ui_cleanup() { [ -n "${UIDIR:-}" ] && rm -rf "$UIDIR"; return 0; }

stop_all_watches() {
    local pid
    for pid in ${WATCH_PIDS[@]+"${WATCH_PIDS[@]}"}; do
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    done
    WATCH_PIDS=(); WATCH_SLOTS=()
    return 0
}

# Count matches in the log rather than in the pipeline. An interactive step
# cannot have its output read line by line - see runi() - so its bar is driven
# by watching what tee has already written to the log.
watch_log_count() { # watch_log_count <file> <ere> <total> <label>
    local f=$1 pat=$2 tot=$3 lbl=$4 n
    while :; do
        n=$(grep -Ec "$pat" "$f" 2>/dev/null) || n=0
        [ "$n" -gt "$tot" ] && tot=$n
        set_progress "$lbl" "$n" "$tot" "${n}/${tot}"
        sleep 1
    done
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
    BAR_SLOT=$(bar_alloc)
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
    bar_free "$BAR_SLOT"; BAR_SLOT=""
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
    find "$KDIR" -name '*.o' 2>/dev/null | wc -l | put_count "$KDIR/.ps3-objcount"
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
    # This step is interactive whichever branch it takes: even with the username
    # supplied it still runs passwd twice and adduser. So it goes through runi(),
    # and the bar is counted off the log instead of out of the pipeline.
    start_watch watch_log_count "$LOG" '^I: (Unpacking|Extracting)' \
        "$ptarget" "unpacking"
    if [ -n "$USERNAME" ]; then
        runi "$SCRIPTS/build-rootfs.sh" "$ROOTFS" "$USERNAME"
    else
        say "${Y}build-rootfs.sh will ask for a username and two passwords.${N}"
        say "${Y}Nothing is shipped or defaulted - you set them now.${N}"
        runi "$SCRIPTS/build-rootfs.sh" "$ROOTFS"
    fi
    stop_watch
    ls "$ROOTFS/var/lib/dpkg/info"/*.list 2>/dev/null | wc -l \
        | put_count "$REPO/.ps3-pkgcount"
}

do_install() {
    phase 5 "kernel into the tree" \
        "Stripping the kernel, installing modules, and building an initrd to" \
        "match. This is the only place a kernel enters the Debian tree."
    [ -n "$KREL" ] || KREL=$(kernelrelease) || fail "cannot determine kernel release"
    pause_for "install kernel $KREL into $ROOTFS" "a minute or two"
    # strip reads the user's tree and writes /tmp; the copy lands in the rootfs
    # tree, which is root's. See the note on $ROOTFS ownership in do_rootfs().
    # Unlink first: an older version of this tool ran the strip as root, and the
    # user cannot overwrite what it left behind.
    rm -f /tmp/vmlinux-stripped
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
    # build-image.sh runs as root - it mounts the image and cp -a has to
    # preserve the ownership inside the tree - but the last run handed this file
    # to the invoking user. mke2fs happens to open an existing image without
    # O_CREAT, so this does not fail today; it is one open flag away from doing
    # so, and root rewriting a file it does not own is the shape that broke the
    # log. Take it back, and let hand_over() give it up again at exit.
    reclaim "$IMG"
    # build-image.sh mounts the image somewhere private, so watch the blocks
    # actually allocated to the sparse image file instead. Same shape, and it
    # is a real measurement rather than a guess.
    start_watch watch_du_file "$IMG" "$tot" "copying tree"
    run "$SCRIPTS/build-image.sh" "$ROOTFS" "$IMG" "$BLOCKS"
    stop_watch
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
trap 'stop_all_watches; cleanup_stick; ui_end; ui_cleanup; hand_over_all' EXIT

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
# Root-owned for the run, the invoking user's group so both privilege levels
# can append, handed over by the EXIT trap. See hand_over().
if [ -n "$RUN_AS_USER" ]; then
    chgrp "$(id -gn "$RUN_AS_USER" 2>/dev/null || echo "$RUN_AS_USER")" \
        "$LOG" 2>/dev/null && chmod 664 "$LOG" 2>/dev/null || true
fi
[ "$(id -u)" = 0 ] || { echo "run with sudo - it writes to $ROOTFS" >&2; exit 1; }

UIDIR=$(mktemp -d) || fail "cannot create a working directory"
ui_state phasenum "0"; ui_state name "starting"
ui_state why ""; ui_state why2 ""

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

ui_state name "finished"
stop_all_watches
[ -n "$UIDIR" ] && rm -f "$UIDIR"/bar.* 2>/dev/null
ui_render
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
