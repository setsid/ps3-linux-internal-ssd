#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a Debian sid ppc64 root filesystem tree for the PS3.
# Runs on the development machine, under qemu-user emulation.
#
#   sudo ./build-rootfs.sh [rootfs-dir] [username]
#
# Defaults: /srv/ps3root, and it will ask for the username.
#
# This produces the userland only. It installs no kernel, no modules and no
# initrd - that is README step 4, which runs against the tree this creates.
# Keeping the two apart means there is exactly one place that installs a
# kernel, so a rebuild cannot leave a stale vmlinux behind.
#
# ppc64 is big-endian and lives in Debian ports, not the main archive, so it
# needs debian-ports-archive-keyring and a qemu-user-static binfmt handler.
#
# CREDENTIALS
#
# This script sets no passwords and contains none. It prompts you, twice,
# during the run: once for root and once for the user it creates. Nothing in
# this repository ships or defaults a credential of any kind. If you are
# automating this, set them yourself afterwards - do not put one in here.
#
# WHY LABEL= AND NOT DEVICE PATHS
#
# The fstab and yaboot.conf written below mount by label. Device naming is not
# stable across this setup: petitboot's kernel and a mainline kernel have
# historically disagreed about which region is which, and the name of the
# OtherOS region changed from ps3da to ps3dd between v1 and v2 of this patch
# set. A label survives all of that; a device path turns a rename into a
# machine that will not boot.
#
# Labels come from README step 5 (ps3root) and partition-region.sh (ps3swap).

set -euo pipefail

ROOTFS="${1:-/srv/ps3root}"
USERNAME="${2:-}"

SUITE=sid
ARCH=ppc64
MIRROR=http://deb.debian.org/debian-ports
KEYRING=/usr/share/keyrings/debian-ports-archive-keyring.gpg
HERE="$(cd "$(dirname "$0")" && pwd)"

# initramfs-tools is installed but not run: mkinitramfs needs modules, which
# arrive in step 4. The tooling has to be here for step 4 to use it.
PACKAGES="
systemd-sysv
systemd-resolved
udev
initramfs-tools
openssh-server
ca-certificates
iproute2
iputils-ping
sudo
wget
e2fsprogs
build-essential
"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

command -v debootstrap >/dev/null || { echo "install debootstrap" >&2; exit 1; }
[ -f "$KEYRING" ] || {
    echo "missing $KEYRING - install debian-ports-archive-keyring" >&2; exit 1; }

# The second stage runs ppc64 binaries on the build machine. Either binfmt_misc
# has qemu registered with the F flag, or we copy the static binary in below.
QEMU=$(command -v qemu-ppc64-static || true)
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-ppc64 ] && [ -z "$QEMU" ]; then
    echo "no qemu-ppc64 binfmt handler and no qemu-ppc64-static" >&2
    echo "install qemu-user-static and binfmt-support" >&2
    exit 1
fi

# Ask again rather than exiting. An empty answer used to end the run outright,
# and it takes very little to produce one: a stray newline already sitting in
# the terminal buffer is enough, and by this point the caller may be twenty
# minutes from being able to try again.
if [ -z "$USERNAME" ]; then
    for _try in 1 2 3; do
        read -r -p "username to create: " USERNAME || USERNAME=""
        [ -n "$USERNAME" ] && break
        echo "a username is required" >&2
    done
fi
[ -n "$USERNAME" ] || { echo "no username given" >&2; exit 1; }

# Always leave the binds unmounted, however this exits.
cleanup() {
    for m in dev/pts dev proc sys; do
        mountpoint -q "$ROOTFS/$m" && umount -l "$ROOTFS/$m" || true
    done
}
trap cleanup EXIT

in_chroot() {
    DEBIAN_FRONTEND=noninteractive LC_ALL=C chroot "$ROOTFS" "$@"
}

# Interactive: passwd and adduser must reach the terminal.
in_chroot_tty() {
    LC_ALL=C chroot "$ROOTFS" "$@"
}

# systemctl is being asked about a root filesystem that is not running, while
# /proc and /sys here belong to the build host. SYSTEMD_OFFLINE=1 is the
# documented way to say so: it stops systemctl consulting the running manager
# and silences the "/proc/ is not mounted" warning, whichever way the binds
# happen to be at the time.
in_chroot_offline() {
    DEBIAN_FRONTEND=noninteractive LC_ALL=C SYSTEMD_OFFLINE=1 \
        chroot "$ROOTFS" "$@"
}

echo "=== stage 1: debootstrap $SUITE/$ARCH into $ROOTFS ==="
mkdir -p "$ROOTFS"
debootstrap --foreign --arch="$ARCH" --keyring="$KEYRING" \
    --include=debian-ports-archive-keyring \
    "$SUITE" "$ROOTFS" "$MIRROR"

if [ -n "$QEMU" ]; then
    cp "$QEMU" "$ROOTFS/usr/bin/"
fi

echo
echo "=== stage 2 ==="
in_chroot /debootstrap/debootstrap --second-stage

echo
echo "=== binds and resolver ==="
mount -t proc  proc  "$ROOTFS/proc"
mount -t sysfs sys   "$ROOTFS/sys"
mount --bind /dev    "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# unreleased carries ports packages that have not reached sid yet
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main
deb $MIRROR unreleased main
EOF

echo
echo "=== packages ==="
in_chroot apt-get update
# shellcheck disable=SC2086
in_chroot apt-get install -y $PACKAGES

# Otherwise every .deb apt downloaded stays in /var/cache/apt/archives - a few
# hundred MB that get packaged into the image and written to the console on
# every rebuild.
in_chroot apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists"/*

echo
echo "=== udev rule ==="
# systemd's 60-persistent-storage.rules does not match ps3d*, so without this
# /dev/disk never appears and the swap unit waits for a by-label link that is
# never created. See docs/troubleshooting.md.
install -D -m 0644 "$HERE/61-ps3-persistent-storage.rules" \
    "$ROOTFS/etc/udev/rules.d/61-ps3-persistent-storage.rules"

echo
echo "=== fstab, yaboot.conf, hostname ==="
cat > "$ROOTFS/etc/fstab" <<'EOF'
# Mount by label. Device naming differs between petitboot and Debian and
# changed between v1 and v2 of the ps3disk patches; labels do not.
#
# errors=remount-ro because a fault in the storage path should stop the machine
# writing rather than carry on corrupting - this driver had exactly that bug.
# noatime because every read otherwise costs a write on a 2009 SATA bridge.
LABEL=ps3root   /       ext4    errors=remount-ro,noatime       0 1
LABEL=ps3swap   none    swap    sw                      0 0
proc            /proc   proc    defaults                0 0
EOF

# /boot/vmlinux and /boot/initrd.img are put here by step 4.
#
# video=ps3fb is what puts output on the television - without it you may get no
# picture at all. net.ifnames=0 forces the interface to eth0, which is what the
# networkd file below matches; leave it out and the name is unpredictable. On a
# headless SSH install, losing either one leaves no way in.
#
# Two entries. The first resolves root by label, which depends on the initramfs
# doing the lookup. The second names the device explicitly and adds the
# conservative flags used during development - free insurance if label
# resolution ever fails.
cat > "$ROOTFS/etc/yaboot.conf" <<'EOF'
# Read by petitboot.
default=debian
timeout=100

image=/boot/vmlinux
	label=debian
	initrd=/boot/initrd.img
	root=LABEL=ps3root
	append="video=ps3fb nomodeset nosplash net.ifnames=0 rw rootdelay=30"

image=/boot/vmlinux
	label=debian-failsafe
	initrd=/boot/initrd.img
	root=/dev/ps3dd1
	append="video=ps3fb nomodeset nosplash net.ifnames=0 rw rootdelay=30 noapic noapm nodma nomce nolapic"
EOF

# Without this the machine comes up with no network at all. systemd-resolved
# handles DNS but configures no link; on a headless SSH install that is a dead
# machine recoverable only with a television and a keyboard. Name=eth0 matches
# because yaboot.conf passes net.ifnames=0.
install -d -m 0755 "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/10-wired.network" <<'EOF'
[Match]
Name=eth0

[Network]
DHCP=yes
EOF

echo ps3 > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	ps3
::1		localhost ip6-localhost ip6-loopback
EOF

echo
echo "=== accounts ==="
echo "Set the root password."
in_chroot_tty passwd
echo
echo "Create $USERNAME. You will be asked for its password."
in_chroot_tty adduser "$USERNAME"
in_chroot adduser "$USERNAME" sudo

# systemctl in a chroot can complain while still doing the right thing, so the
# exit status is not worth much - but the outcome is. The README promises the
# machine comes up reachable over SSH on DHCP, and if networkd is not actually
# enabled the user boots a PS3 with no network and no way in except a
# television, after being told the build succeeded. Check the symlinks.
# Full unit names: bare "ssh" is ambiguous now that openssh ships an ssh.socket
# alongside ssh.service.
in_chroot_offline systemctl enable ssh.service || true
in_chroot_offline systemctl enable systemd-networkd.service || true
in_chroot_offline systemctl enable systemd-resolved.service || true

# Enabled means systemd says so, or a wants symlink points at a unit file that
# exists. Resolve that target inside the tree: the symlinks systemd writes are
# absolute, so testing one from the build host with [ -e ] follows it into the
# host's own /usr/lib/systemd/system. That silently passes for every unit the
# host happens to have installed and fails for the ones it does not - which is
# how a correctly enabled ssh.service came back as NOT enabled on a host with
# systemd but no openssh-server, while networkd and resolved passed.
unit_enabled() { # unit_enabled <unit>
    local l t
    [ "$(in_chroot_offline systemctl is-enabled "$1" 2>/dev/null)" = enabled ] \
        && return 0
    for l in "$ROOTFS/etc/systemd/system"/*.target.wants/"$1"; do
        [ -L "$l" ] || continue
        t=$(readlink "$l")
        case "$t" in
            /*) [ -e "$ROOTFS$t" ] && return 0 ;;
            *)  [ -e "${l%/*}/$t" ] && return 0 ;;
        esac
    done
    return 1
}

echo
echo "=== checking services are really enabled ==="
# The glob in unit_enabled covers every *.target.wants, so resolved linking from
# sysinit rather than multi-user needs no special case here.
missing=
for unit in ssh.service systemd-networkd.service systemd-resolved.service; do
    if unit_enabled "$unit"; then
        echo "  $unit enabled"
    else
        echo "  $unit NOT enabled"
        missing="$missing $unit"
    fi
done

if [ -n "$missing" ]; then
    echo
    echo "FAILED: these services are not enabled:$missing"
    echo "The machine would boot without them. Fix before building an image:"
    echo "  SYSTEMD_OFFLINE=1 chroot $ROOTFS systemctl enable$missing"
    echo
    echo "The tree itself is built and nothing above this is lost. After that"
    echo "command, run make-debian-installer.sh again - it resumes from what is"
    echo "already done and will not rebuild the tree."
    exit 1
fi

# The resolv.conf copied in for the chroot points at the build host's resolver,
# which the PS3 cannot reach. Hand DNS to systemd-resolved instead.
rm -f "$ROOTFS/etc/resolv.conf"
in_chroot ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# The emulator stays in the tree deliberately. README step 4 chroots in here to
# run mkinitramfs, and on a host whose binfmt handler lacks the F flag the
# interpreter is not held open across the chroot - the copy inside the tree is
# what makes that work. build-image.sh removes it from the image instead, so
# nothing useless reaches the console.

echo
echo "=== unmounting ==="
cleanup
trap - EXIT

echo
echo "=== result ==="
cat "$ROOTFS/etc/fstab"
du -sh "$ROOTFS"

echo
echo "Userland only - there is no kernel in this tree yet."
echo "Next: README step 4 installs the kernel, modules and initrd into"
echo "$ROOTFS, then step 5 packages it."
