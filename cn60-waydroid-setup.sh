#!/usr/bin/env bash
# CN60 Waydroid kiosk for Debian 13 x86_64: boots straight into Waydroid
# fullscreen (cage, no desktop environment), tunes the OS for kiosk use,
# keeps Debian + Android updated, enables SSH, updates itself from GitHub, and
# shows update notifications inside Android. Settings menu on Ctrl+Alt+F2.
#
#   sudo ./cn60-waydroid-setup.sh                    install; if already installed, add only what is new
#   sudo ./cn60-waydroid-setup.sh --no-upgrade       same, but skip the Debian/Android upgrade
#   sudo ./cn60-waydroid-setup.sh --force            redo every step, even ones already done
#   sudo ./cn60-waydroid-setup.sh --aurora           install Aurora Store without asking
#   sudo ./cn60-waydroid-setup.sh --no-aurora        do not install Aurora Store, do not ask
#   sudo ./cn60-waydroid-setup.sh --uninstall        remove everything this script added
#   sudo ./cn60-waydroid-setup.sh --uninstall --yes  same, without the confirmation prompt
#
# Status: syntax-checked only (bash -n). Not run on the CN60 hardware.
# Self-contained: writes the settings menu and updater to /usr/local/bin.

set -euo pipefail

SCRIPT_VERSION=15              # bump when the script changes
STATE=/etc/cn60
MARK=$STATE/installed          # present once a full install finished
STEPS=$STATE/steps             # one file per one-time step, holding the step version
BACKUP=$STATE/backup           # originals of system files this script edits
PKGS_ADDED=$STATE/packages-added
GROUPS_ADDED=$STATE/groups-added
MASKED=$STATE/masked           # units this script masked
DISABLED=$STATE/disabled       # units this script disabled
ENABLED=$STATE/enabled         # units this script enabled (besides its own)
USER_FILE=$STATE/user
OPTIONS=$STATE/options         # answers to install questions (asked once)
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
MODE=install
ASSUME_YES=0
FORCE=0
UPGRADE=1
AURORA_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --uninstall)  MODE=uninstall ;;
        --yes)        ASSUME_YES=1 ;;
        --force)      FORCE=1 ;;
        --no-upgrade) UPGRADE=0 ;;
        --aurora)     AURORA_FLAG=yes ;;
        --no-aurora)  AURORA_FLAG=no ;;
        -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)            die "Unknown option: $arg" ;;
    esac
done

# Re-run as root, keeping the invoking user so Waydroid can run as them.
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "Run as root (sudo)."
    exec sudo -E bash "$0" "$@"
fi

KUSER="${SUDO_USER:-}"
if [[ -z "$KUSER" || "$KUSER" == root ]]; then
    [[ -r $USER_FILE ]] && KUSER="$(cat "$USER_FILE")"
fi
[[ -n "$KUSER" && "$KUSER" != root ]] || \
    die "Run with sudo from your normal user account, not from a root login."
id "$KUSER" >/dev/null 2>&1 || die "User '$KUSER' does not exist."

CHANGES=()                     # what this run added or changed, printed at the end

# ------------------------------------------------------------------ helpers
# record <file> <line>: append a line once (state lists used by uninstall).
record() {
    mkdir -p "$STATE"
    grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}

# backup_once <path>: keep the original of a system file before the first edit.
backup_once() {
    local b="$BACKUP$1"
    [[ -e $b || -e $b.absent ]] && return 0
    mkdir -p "$(dirname "$b")"
    if [[ -e $1 ]]; then cp -a "$1" "$b"; else touch "$b.absent"; fi
}

# put_file <path> <mode> [backup]: write stdin to path only if the content changed.
put_file() {
    local path=$1 mode=$2 tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; chmod "$mode" "$path"; return 0
    fi
    [[ ${3:-} == backup ]] && backup_once "$path"
    # Write next to the target, then rename: scripts that are running keep reading the old copy.
    install -D -m "$mode" "$tmp" "$path.cn60new"
    mv -f "$path.cn60new" "$path"
    rm -f "$tmp"
    CHANGES+=("wrote $path")
}

# set_kv <file> <key> <value>: set KEY=value, uncommenting or appending as needed.
set_kv() {
    if grep -qE "^#?[[:space:]]*$2=" "$1"; then
        sed -i -E "s|^#?[[:space:]]*$2=.*|$2=$3|" "$1"
    else
        echo "$2=$3" >> "$1"
    fi
}

# Install questions: asked once, answer kept in /etc/cn60/options.
opt_get() { sed -n "s/^$1=//p" "$OPTIONS" 2>/dev/null | tail -n1; }
opt_set() {
    mkdir -p "$STATE"; touch "$OPTIONS"
    if grep -q "^$1=" "$OPTIONS"; then sed -i "s|^$1=.*|$1=$2|" "$OPTIONS"
    else echo "$1=$2" >> "$OPTIONS"; fi
}

ask_options() {
    [[ -n $AURORA_FLAG ]] && opt_set AURORA_STORE "$AURORA_FLAG"
    if [[ -z "$(opt_get AURORA_STORE)" ]]; then
        if [[ -t 0 && $ASSUME_YES -eq 0 ]]; then
            cat <<'EOM'

Aurora Store is an open-source app store that downloads apps from Google Play
without Google's own apps. You can sign in anonymously. Apps that need Google
Play Services (some games, banking, Google apps) may not work.
EOM
            local a
            read -rp "Install Aurora Store in Android? [Y/n] " a
            case "$a" in
                n|N|no|NO) opt_set AURORA_STORE no ;;
                *)         opt_set AURORA_STORE yes ;;
            esac
            CHANGES+=("Aurora Store: $(opt_get AURORA_STORE)")
        else
            echo "  Aurora Store: not asked (no keyboard on this run). Later: sudo cn60-apps aurora"
        fi
    fi
}

unit_state() { systemctl is-enabled "$1" 2>/dev/null || true; }
unit_exists() { [[ -n "$(systemctl list-unit-files "$1" --no-legend 2>/dev/null)" ]]; }

# run_step <name> <version> <function>: one-time steps; rerun only when the version changes.
run_step() {
    local name=$1 ver=$2 fn=$3
    if [[ $FORCE -eq 0 && -f $STEPS/$name && "$(cat "$STEPS/$name")" == "$ver" ]]; then
        echo "  $name: already done (v$ver)"
        return 0
    fi
    if "$fn"; then
        mkdir -p "$STEPS"; echo "$ver" > "$STEPS/$name"
        CHANGES+=("step $name v$ver")
    else
        warn "$name did not finish; it will be retried next run."
    fi
}

check_platform() {
    [[ "$(uname -m)" == x86_64 ]] || die "Needs x86_64; this machine is $(uname -m)."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || \
        warn "Expected Debian 13, found ${PRETTY_NAME:-unknown}. Continuing."
}

# ---------------------------------------------------------------- uninstall
do_uninstall() {
    if [[ $ASSUME_YES -eq 0 ]]; then
        [[ -t 0 ]] || die "Non-interactive uninstall needs --yes."
        echo "This removes the kiosk, Waydroid and its data (/var/lib/waydroid, ~$KUSER/.local/share/waydroid),"
        echo "the OS tweaks and auto-updates, the packages this script added, and group memberships it added."
        echo "If this script installed SSH it is removed too: run this from the box, not over SSH."
        read -rp "Type UNINSTALL to continue: " confirm
        [[ "$confirm" == UNINSTALL ]] || die "Cancelled."
    fi

    log "Stopping the kiosk and returning to a normal boot"
    systemctl disable --now waydroid-kiosk.service cn60-update.timer cn60-check.timer 2>/dev/null || true
    systemctl set-default multi-user.target
    runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
    systemctl disable --now waydroid-container.service 2>/dev/null || true

    log "Removing systemd units and helper scripts"
    rm -f /etc/systemd/system/waydroid-kiosk.service \
          /etc/systemd/system/cn60-fallback.service \
          /etc/systemd/system/graphical-kiosk.target \
          /etc/systemd/system/cn60-update.service \
          /etc/systemd/system/cn60-update.timer \
          /etc/systemd/system/cn60-check.service \
          /etc/systemd/system/cn60-check.timer
    rm -f /usr/local/bin/cn60-kiosk-start /usr/local/bin/cn60-kiosk-user \
          /usr/local/bin/cn60-settings /usr/local/bin/cn60-update \
          /usr/local/bin/cn60-check /usr/local/bin/cn60-remote /usr/local/bin/cn60-apps \
          /usr/local/bin/cn60-crashlog /usr/local/bin/cn60-tweaks /etc/update-motd.d/90-cn60
    rm -rf /usr/local/lib/cn60 /var/lib/cn60 /etc/systemd/system/waydroid-container.service.d/90-cn60.conf

    log "Reverting OS tweaks"
    if [[ -r $STATE/swapfile ]]; then
        local sf
        sf="$(cat "$STATE/swapfile")"
        if [[ -n $sf ]]; then
            swapoff "$sf" 2>/dev/null || warn "Could not turn off $sf (not enough free RAM?); it is removed after reboot."
            sed -i "\|^${sf}[[:space:]]|d" /etc/fstab
            rm -f "$sf"
        fi
    fi
    rm -f /etc/sysctl.d/90-cn60.conf \
          /etc/systemd/journald.conf.d/90-cn60.conf \
          /etc/systemd/system.conf.d/90-cn60.conf \
          /etc/apt/apt.conf.d/52cn60-unattended \
          /etc/ssh/sshd_config.d/90-cn60.conf \
          /etc/wireplumber/wireplumber.conf.d/80-cn60-bluetooth.conf
    [[ -r $MASKED ]]   && while read -r u; do [[ -n $u ]] && systemctl unmask "$u" 2>/dev/null || true; done < "$MASKED"
    [[ -r $DISABLED ]] && while read -r u; do [[ -n $u ]] && systemctl enable "$u" 2>/dev/null || true; done < "$DISABLED"
    [[ -r $ENABLED ]]  && while read -r u; do [[ -n $u ]] && systemctl disable "$u" 2>/dev/null || true; done < "$ENABLED"
    if [[ -d $BACKUP ]]; then
        while IFS= read -r b; do
            local target=${b#"$BACKUP"}
            if [[ $target == *.absent ]]; then rm -f "${target%.absent}"
            else cp -a "$b" "$target"; fi
        done < <(find "$BACKUP" -type f)
        [[ -e $BACKUP/etc/default/grub ]] && { update-grub || warn "update-grub failed."; }
    fi
    systemctl daemon-reload

    log "Removing Waydroid data, ARM translation and CN60 config"
    rm -rf /var/lib/waydroid "/home/$KUSER/.local/share/waydroid" \
           "/home/$KUSER/.share/waydroid" /opt/waydroid_script
    rm -f /etc/modules-load.d/waydroid-binder.conf /etc/modprobe.d/waydroid-binder.conf
    loginctl disable-linger "$KUSER" 2>/dev/null || true

    log "Removing group memberships this script added"
    if [[ -r $GROUPS_ADDED ]]; then
        while read -r user group; do
            [[ -n "${user:-}" ]] && gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
        done < "$GROUPS_ADDED"
    fi

    log "Purging packages this script installed (packages that were already present are kept)"
    if [[ -r $PKGS_ADDED ]]; then
        # shellcheck disable=SC2046
        "${APT[@]}" purge $(cat "$PKGS_ADDED") || warn "Some packages failed to purge."
        "${APT[@]}" autoremove || true
    fi

    rm -rf "$STATE"
    echo
    echo "Uninstall complete. Reboot now: sudo reboot"
    exit 0
}

# ------------------------------------------------------------------ install
install_packages() {
    log "Checking packages (installs only what is missing)"
    local want=(waydroid lxc dnsmasq-base nftables cage seatd bluez cec-utils whiptail
                python3-venv python3-pip git curl ca-certificates
                build-essential dkms "linux-headers-$(uname -r)" linux-headers-amd64
                zram-tools unattended-upgrades openssh-server)
    # Sound for Android (HDMI and Bluetooth headphones/speakers) goes through the host's audio server.
    if dpkg -s pulseaudio >/dev/null 2>&1; then
        want+=(pulseaudio-module-bluetooth)
    else
        want+=(pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth)
    fi
    local missing=()
    for p in "${want[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then missing+=("$p"); fi
    done
    "${APT[@]}" update
    if [[ ${#missing[@]} -gt 0 ]]; then
        "${APT[@]}" install "${missing[@]}"
        for p in "${missing[@]}"; do record "$PKGS_ADDED" "$p"; done
        CHANGES+=("installed ${missing[*]}")
    else
        echo "  all packages present"
    fi
}

ensure_user_groups() {
    log "Checking $KUSER's device groups"
    local seat_group=seat
    getent group _seatd >/dev/null && seat_group=_seatd
    for g in video render input "$seat_group"; do
        getent group "$g" >/dev/null || continue
        if ! id -nG "$KUSER" | tr ' ' '\n' | grep -qx "$g"; then
            usermod -aG "$g" "$KUSER"
            record "$GROUPS_ADDED" "$KUSER $g"
            CHANGES+=("added $KUSER to $g")
        fi
    done
    # Keeps /run/user/<uid> alive so Waydroid's session bus exists at boot.
    loginctl enable-linger "$KUSER"
}

ensure_binder() {
    log "Checking binder kernel support"
    if ! lsmod | grep -q '^binder_linux'; then
        modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
    fi
    if [[ ! -e /dev/binder && ! -e /dev/binderfs/binder-control ]]; then
        mkdir -p /dev/binderfs
        mount -t binder binder /dev/binderfs 2>/dev/null || true
    fi
    if [[ ! -e /dev/binder && ! -e /dev/binderfs/binder-control ]]; then
        die "No binder support in this kernel (CONFIG_ANDROID_BINDER_IPC missing). Waydroid cannot run on this box."
    fi
    put_file /etc/modules-load.d/waydroid-binder.conf 644 <<< "binder_linux"
    put_file /etc/modprobe.d/waydroid-binder.conf 644 \
        <<< 'options binder_linux devices="binder,hwbinder,vndbinder"'
}

write_config() {
    # display.conf is written only when missing, so re-running never overwrites a user's choice.
    mkdir -p "$STATE"
    echo "$KUSER" > "$USER_FILE"
    if [[ ! -f $STATE/display.conf ]]; then
        printf 'WIDTH=1920\nHEIGHT=1080\n' > "$STATE/display.conf"
        CHANGES+=("created $STATE/display.conf (1920x1080)")
    fi
    chmod 644 "$STATE/display.conf"
    # update.conf is also written only when missing (it may hold a GitHub token, so root-only).
    if [[ ! -f $STATE/update.conf ]]; then
        cat > "$STATE/update.conf" <<'EOF'
# CN60 self-update settings (read by cn60-check and cn60-update)
# GitHub repo and branch that hold cn60-waydroid-setup.sh
REPO=carongutermuth113/cn60-waydroid-kiosk
BRANCH=main
# Read-only token, needed only while the repo is private (fine-grained, Contents: Read-only)
GITHUB_TOKEN=
# yes = the weekly update installs new script versions automatically; no = only notify
AUTO_APPLY_SCRIPT=yes
# yes = show update notifications inside Android
NOTIFY=yes
EOF
        CHANGES+=("created $STATE/update.conf")
    fi
    chmod 600 "$STATE/update.conf"
}

upgrade_debian() {
    log "Upgrading Debian packages"
    "${APT[@]}" full-upgrade || { warn "Debian upgrade failed; continuing."; return 0; }
    "${APT[@]}" autoremove --purge || true
    "${APT[@]}" autoclean || true
}

# ---- OS tuning (one-time step; bump its version in do_install when it changes)
tune_os() {
    log "Tuning the OS for kiosk use"
    # Memory (sysctl, zram, swap file) is handled by tune_memory, which runs every time.

    # Logs: cap the journal so the disk does not fill up over months.
    put_file /etc/systemd/journald.conf.d/90-cn60.conf 644 <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald || true

    # Faster shutdown/reboot when a service hangs.
    put_file /etc/systemd/system.conf.d/90-cn60.conf 644 <<'EOF'
[Manager]
DefaultTimeoutStopSec=15s
EOF

    # Never suspend or hibernate; don't wait for the network at boot.
    local u
    for u in sleep.target suspend.target hibernate.target hybrid-sleep.target \
             NetworkManager-wait-online.service systemd-networkd-wait-online.service; do
        unit_exists "$u" || continue
        [[ "$(unit_state "$u")" == masked ]] && continue
        systemctl mask "$u" >/dev/null 2>&1 && record "$MASKED" "$u"
    done

    # Services a TV box does not need.
    for u in ModemManager.service cups.service cups-browsed.service; do
        [[ "$(unit_state "$u")" == enabled ]] || continue
        systemctl disable --now "$u" >/dev/null 2>&1 && record "$DISABLED" "$u"
    done

    # Weekly SSD/eMMC TRIM.
    if unit_exists fstrim.timer && [[ "$(unit_state fstrim.timer)" != enabled ]]; then
        systemctl enable --now fstrim.timer >/dev/null 2>&1 && record "$ENABLED" fstrim.timer
    fi

    # Boot: 1 s GRUB menu, quiet boot, no console blanking.
    if [[ -f /etc/default/grub ]] && command -v update-grub >/dev/null; then
        backup_once /etc/default/grub
        local f=/etc/default/grub cur new p key
        set_kv "$f" GRUB_TIMEOUT 1
        cur="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$f" | tail -n1)"
        new="$cur"
        for p in quiet loglevel=3 consoleblank=0; do
            key=${p%%=*}
            if ! printf ' %s ' "$new" | grep -qE " $key(=| )"; then new="${new:+$new }$p"; fi
        done
        if [[ "$new" != "$cur" ]] || ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
            new="$(printf '%s' "$new" | sed 's/[&|\\]/\\&/g')"
            if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
                sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" "$f"
            else
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"" >> "$f"
            fi
        fi
        update-grub || warn "update-grub failed; boot settings unchanged."
    else
        warn "GRUB not found; skipping boot tweaks."
    fi
    systemctl daemon-reload
    return 0
}

# ---- Network clash fix (one-time step)
# Waydroid runs its own bridge (waydroid0) with its own dnsmasq. The system-wide dnsmasq
# daemon and LXC's default bridge (lxc-net, lxcbr0) are not needed. They fight over
# port 53, so lxc-net fails at boot ("Failed to start lxc-net.service").
fix_network_clash() {
    log "Disabling dnsmasq.service and lxc-net.service (Waydroid does not use them)"
    local u
    for u in dnsmasq.service lxc-net.service; do
        unit_exists "$u" || continue
        case "$(unit_state "$u")" in
            enabled|enabled-runtime)
                systemctl disable --now "$u" >/dev/null 2>&1 && record "$DISABLED" "$u" ;;
            *)  systemctl stop "$u" >/dev/null 2>&1 || true ;;
        esac
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
    done
    # Remove a leftover lxcbr0 bridge so it cannot hold the address range.
    ip link show lxcbr0 >/dev/null 2>&1 && ip link delete lxcbr0 2>/dev/null || true
    systemctl restart waydroid-container.service || warn "waydroid-container did not restart."
    return 0
}

# ---- Bluetooth audio fix (one-time step)
# WirePlumber only offers Bluetooth audio to a user that has an active logind seat session.
# The kiosk runs without one, so headphones/speakers fail with
# "br-connection-profile-unavailable". Turn seat monitoring off for Bluetooth.
fix_bt_audio() {
    log "Allowing Bluetooth audio without a desktop login (WirePlumber)"
    put_file /etc/wireplumber/wireplumber.conf.d/80-cn60-bluetooth.conf 644 <<'EOF'
# CN60 kiosk: Bluetooth audio without a logind seat session (removed on uninstall)
wireplumber.profiles = {
  main = {
    monitor.bluez.seat-monitoring = disabled
  }
}
EOF
    systemctl --user -M "$KUSER@" restart wireplumber.service pipewire-pulse.service >/dev/null 2>&1 \
        || echo "  WirePlumber restarts with the next kiosk restart or reboot."
    return 0
}

# ---- Self-update checks + Android notifications (one-time step)
setup_self_update() {
    log "Turning on daily update checks (new script version on GitHub, Debian updates)"
    systemctl daemon-reload
    systemctl enable --now cn60-check.timer || { warn "Could not enable cn60-check.timer."; return 1; }
}

# ---- SSH remote access (one-time step)
setup_ssh() {
    log "Setting up SSH remote access"
    put_file /etc/ssh/sshd_config.d/90-cn60.conf 644 <<'EOF'
# CN60: SSH for normal users only (removed by cn60-waydroid-setup.sh --uninstall)
PermitRootLogin no
MaxAuthTries 4
X11Forwarding no
EOF
    if ! sshd -t; then
        warn "SSH config test failed; removing the CN60 SSH settings."
        rm -f /etc/ssh/sshd_config.d/90-cn60.conf
        return 1
    fi
    if [[ "$(unit_state ssh.service)" != enabled ]]; then
        systemctl enable ssh.service >/dev/null 2>&1 && record "$ENABLED" ssh.service
    fi
    systemctl restart ssh.service || { warn "SSH did not start: journalctl -u ssh -b"; return 1; }
}

# ---- Automatic updates (one-time step)
setup_auto_updates() {
    log "Turning on automatic updates"
    # Daily: Debian security/stable updates through unattended-upgrades. Never auto-reboots.
    put_file /etc/apt/apt.conf.d/20auto-upgrades 644 backup <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    put_file /etc/apt/apt.conf.d/52cn60-unattended 644 <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    # Weekly: full upgrade + Android image via cn60-update (timer written in write_helpers).
    systemctl daemon-reload
    systemctl enable --now cn60-update.timer || { warn "Could not enable cn60-update.timer."; return 1; }
}

setup_waydroid() {
    log "Checking the Waydroid container"
    systemctl enable --now waydroid-container.service
    if [[ ! -f /var/lib/waydroid/images/system.img ]]; then
        log "Initialising Waydroid (vanilla, no GApps; downloads 1-2 GB)"
        waydroid init -s VANILLA || die "waydroid init failed; fix the error above and re-run."
        CHANGES+=("initialised Waydroid")
    else
        echo "  Waydroid images present"
    fi
}

# stop_android: stop the kiosk and the Android session before changing the Android image.
# do_install restarts the kiosk at the end if it was running when the script started.
stop_android() {
    systemctl stop waydroid-kiosk.service 2>/dev/null || true
    runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
}

# ---- ARM translation (one-time step)
# Most Play Store apps ship ARM code only. Intel CPUs (the CN60) run it best with Intel's
# libhoudini; libndk (used up to script v10) suits AMD and makes many apps crash on Intel.
install_arm_translation() {
    local arm=libndk arm_old=libhoudini py=/opt/waydroid_script/venv/bin/python3
    if grep -q GenuineIntel /proc/cpuinfo; then arm=libhoudini; arm_old=libndk; fi
    log "Installing ARM translation ($arm) for ARM-only apps (third-party project)"
    if [[ ! -d /opt/waydroid_script/venv ]]; then
        rm -rf /opt/waydroid_script
        git clone --depth 1 https://github.com/casualsnek/waydroid_script /opt/waydroid_script \
            || { warn "Could not clone waydroid_script; ARM apps unavailable."; return 1; }
        python3 -m venv /opt/waydroid_script/venv || return 1
    else
        git -C /opt/waydroid_script pull -q --ff-only || warn "Could not update waydroid_script; using the old copy."
    fi
    /opt/waydroid_script/venv/bin/pip install -q -r /opt/waydroid_script/requirements.txt \
        || { warn "pip install for waydroid_script failed; ARM apps unavailable."; return 1; }
    stop_android
    # Only one translator may be installed; remove the other one (harmless if it is absent).
    (cd /opt/waydroid_script && "$py" main.py uninstall "$arm_old") >/dev/null 2>&1 || true
    (cd /opt/waydroid_script && "$py" main.py install "$arm") \
        || { warn "ARM translation install failed; x86 apps still work."; return 1; }
}

# ---- Low-RAM tuning (always checked)
# The CN60 has 4 GB of RAM. Debian + Android + one big app do not fit, so the kernel or
# Android's memory killer closes apps. Fix: compressed RAM swap (zram, about 3:1) used early,
# plus a swap file on disk as the last resort before anything is killed.
SWAPFILE=/cn60.swap
SWAP_GB=4
tune_memory() {
    log "Checking low-memory tuning (4 GB RAM)"
    put_file /etc/sysctl.d/90-cn60.conf 644 <<'EOF'
# CN60 kiosk memory tuning for 4 GB RAM (removed by cn60-waydroid-setup.sh --uninstall)
# zram swap is fast, so move idle memory there early instead of killing apps.
vm.swappiness=150
vm.page-cluster=0
vm.watermark_scale_factor=125
vm.watermark_boost_factor=0
vm.vfs_cache_pressure=100
EOF
    sysctl --system >/dev/null 2>&1 || warn "sysctl reload failed; applies after reboot."

    # zram: compressed swap in RAM, size = 100% of RAM (zstd), used before the disk.
    if [[ -f /etc/default/zramswap ]]; then
        backup_once /etc/default/zramswap
        local before
        before="$(cat /etc/default/zramswap)"
        set_kv /etc/default/zramswap ALGO zstd
        set_kv /etc/default/zramswap PERCENT 100
        set_kv /etc/default/zramswap PRIORITY 100
        systemctl enable zramswap.service >/dev/null 2>&1 || true
        if ! swapon --show=NAME --noheadings | grep -q zram; then
            systemctl restart zramswap.service && CHANGES+=("zram swap on (100% of RAM, zstd)") \
                || warn "zram swap did not start; continuing."
        elif [[ "$before" != "$(cat /etc/default/zramswap)" ]]; then
            # Restarting zram now would pull everything swapped back into RAM at once.
            CHANGES+=("zram swap resized to 100% of RAM (applies after reboot)")
        fi
    else
        warn "zram-tools config missing; skipping zram swap."
    fi

    # Swap file on disk: used only when zram is full (lower priority).
    if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
        :
    elif [[ -f $SWAPFILE ]]; then
        swapon -p 10 "$SWAPFILE" 2>/dev/null || warn "Could not enable $SWAPFILE."
    else
        local fs avail
        fs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
        avail="$(df --output=avail -BG / 2>/dev/null | tail -n1 | tr -dc 0-9)"
        if [[ $fs != ext4 && $fs != xfs ]]; then
            warn "Swap file skipped: the root filesystem is '${fs:-unknown}', not ext4/xfs."
        elif (( ${avail:-0} < SWAP_GB + 8 )); then
            warn "Swap file skipped: only ${avail:-0} GB free on / (need $((SWAP_GB + 8)) GB)."
        elif fallocate -l "${SWAP_GB}G" "$SWAPFILE" && chmod 600 "$SWAPFILE" \
             && mkswap -L cn60swap "$SWAPFILE" >/dev/null && swapon -p 10 "$SWAPFILE"; then
            echo "$SWAPFILE" > "$STATE/swapfile"
            CHANGES+=("added a ${SWAP_GB} GB swap file ($SWAPFILE)")
        else
            swapoff "$SWAPFILE" 2>/dev/null || true
            rm -f "$SWAPFILE"
            warn "Could not create the swap file; continuing with zram only."
        fi
    fi
    if [[ -f $SWAPFILE ]] && ! grep -q "^${SWAPFILE}[[:space:]]" /etc/fstab; then
        backup_once /etc/fstab
        echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
        CHANGES+=("swap file enabled at boot (/etc/fstab)")
        systemctl daemon-reload
    fi

    # If Debian itself runs out of memory, its OOM killer must pick something other than
    # Android's container or the kiosk screen (that would close everything at once).
    put_file /etc/systemd/system/waydroid-container.service.d/90-cn60.conf 644 <<'EOF'
# CN60: protect Android from the host OOM killer (removed by --uninstall)
[Service]
OOMScoreAdjust=-500
EOF
    systemctl daemon-reload
    return 0
}

# ---- Android memory settings (always checked)
# Bigger per-app Java heap: heavy apps (video, games) otherwise die with OutOfMemoryError.
# Written to the [properties] section of waydroid.cfg; Waydroid copies it into the
# Android image's properties on every `waydroid upgrade` (also --offline), so it survives updates.
ANDROID_PROPS=(dalvik.vm.heapgrowthlimit=256m dalvik.vm.heapsize=512m)
tune_android() {
    log "Checking Android memory settings"
    local cfg=/var/lib/waydroid/waydroid.cfg out
    [[ -f $cfg ]] || { warn "$cfg missing; skipping Android memory settings."; return 0; }
    out="$(python3 - "$cfg" "${ANDROID_PROPS[@]}" <<'PY'
import configparser, sys
path, props = sys.argv[1], sys.argv[2:]
c = configparser.ConfigParser()
c.read(path)
if not c.has_section("properties"):
    c.add_section("properties")
changed = False
for kv in props:
    k, v = kv.split("=", 1)
    if c.get("properties", k, fallback=None) != v:
        c.set("properties", k, v)
        changed = True
if changed:
    with open(path + ".cn60new", "w") as f:
        c.write(f)
    print("changed")
PY
)" || { warn "Could not edit $cfg."; rm -f "$cfg.cn60new"; return 0; }
    if [[ $out == changed ]]; then
        backup_once "$cfg"
        mv -f "$cfg.cn60new" "$cfg"
        stop_android
        if waydroid upgrade --offline >/dev/null 2>&1; then
            CHANGES+=("Android: larger app memory limit (${ANDROID_PROPS[*]})")
        else
            warn "waydroid upgrade --offline failed; the Android memory settings apply after the next 'sudo cn60-update'."
        fi
    else
        echo "  Android memory settings present"
    fi
    return 0
}

write_helpers() {
    log "Checking the kiosk helpers and systemd units (only changed files are rewritten)"

    # Settings menu (embedded, so this script is the only file you need).
    put_file /usr/local/bin/cn60-settings 755 <<'CN60_SETTINGS_EOF'
#!/usr/bin/env bash
# CN60 settings menu: resolution, TV tweaks, Bluetooth, TV power (HDMI-CEC), SSH info, updates.
# Written by cn60-waydroid-setup.sh. Run with sudo from a console.
set -uo pipefail

CONF=/etc/cn60/display.conf
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo cn60-settings"; exit 1; }
command -v whiptail >/dev/null || { echo "whiptail missing"; exit 1; }

apply_resolution() {
    local w="$1" h="$2"
    mkdir -p /etc/cn60
    printf 'WIDTH=%s\nHEIGHT=%s\n' "$w" "$h" > "$CONF"
    [[ -x /usr/local/bin/cn60-tweaks ]] && /usr/local/bin/cn60-tweaks density-follow >/dev/null 2>&1
    waydroid prop set persist.waydroid.width "$w" || true
    waydroid prop set persist.waydroid.height "$h" || true
    systemctl restart waydroid-kiosk.service
    whiptail --msgbox "Resolution set to ${w}x${h}. Kiosk restarted." 8 50
}

menu_resolution() {
    local choice
    choice=$(whiptail --title "Resolution" --menu "Choose a display mode" 15 60 5 \
        1080p "1920x1080 (default)" \
        4k    "3840x2160" \
        720p  "1280x720" \
        back  "Return" 3>&1 1>&2 2>&3) || return
    case "$choice" in
        4k)    apply_resolution 3840 2160 ;;
        1080p) apply_resolution 1920 1080 ;;
        720p)  apply_resolution 1280 720 ;;
        back)  ;;
    esac
}

# Bluetooth: devices pair with Debian. Keyboards, mice, gamepads and remotes then
# work in Android as normal input; headphones/speakers play Android's sound.
bt_pick() {   # bt_pick <filter: Paired|Connected|""> <title>; sets BT_MAC
    local items=() mac name
    while read -r _ mac name; do
        [[ $mac =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] && items+=("$mac" "${name:-unknown}")
    done < <(bluetoothctl devices $1 2>/dev/null)
    if [[ ${#items[@]} -eq 0 ]]; then
        whiptail --msgbox "No devices found." 7 40; return 1
    fi
    BT_MAC=$(whiptail --title "$2" --menu "Choose a device" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3)
}

bt_run() {    # show the commands' output on screen (passkeys appear here)
    clear
    echo "$1"; echo
    shift
    local out
    for c in "$@"; do
        echo "\$ bluetoothctl $c"
        out=$(eval "bluetoothctl $c" 2>&1); echo "$out"; echo
        if [[ $out == *profile-unavailable* ]]; then
            echo "Hint: no Debian service can handle this device. Headphones/speakers need the"
            echo "audio server: run 'sudo cn60-update' (script v10+) and reboot. Phones and PCs"
            echo "cannot be connected this way at all."
            echo
        fi
    done
    read -rp "Press Enter to continue " _
}

bt_pair() {
    whiptail --msgbox "Put the device in pairing mode now (usually hold its pairing or power button until a light flashes), then press OK. Scanning takes 20 seconds." 10 64
    clear; echo "Scanning for 20 seconds..."
    bluetoothctl --timeout 20 scan on >/dev/null 2>&1
    bt_pick "" "Devices found" || return
    bt_run "Pairing $BT_MAC. If a code appears, type it on the keyboard and press Enter." \
        "pair $BT_MAC" "trust $BT_MAC" "connect $BT_MAC"
}

bt_status() {
    local paired connected
    paired=$(bluetoothctl devices Paired 2>/dev/null | cut -d' ' -f2-)
    connected=$(bluetoothctl devices Connected 2>/dev/null | cut -d' ' -f2-)
    whiptail --title "Bluetooth status" --msgbox \
        "Paired:\n${paired:-none}\n\nConnected now:\n${connected:-none}" 20 74
}

menu_bluetooth() {
    systemctl start bluetooth.service
    rfkill unblock bluetooth 2>/dev/null || true
    bluetoothctl power on >/dev/null 2>&1
    local choice
    while true; do
        choice=$(whiptail --title "Bluetooth" --menu "Keyboards, mice, gamepads, remotes, headphones, speakers" 16 70 6 \
            pair       "Scan and pair a new device" \
            status     "Show paired and connected devices" \
            connect    "Reconnect a paired device" \
            disconnect "Disconnect a device" \
            remove     "Forget a device" \
            back       "Return" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            pair)       bt_pair ;;
            status)     bt_status ;;
            connect)    bt_pick Paired "Reconnect" && bt_run "Connecting $BT_MAC" "connect $BT_MAC" ;;
            disconnect) bt_pick Connected "Disconnect" && bt_run "Disconnecting $BT_MAC" "disconnect $BT_MAC" ;;
            remove)     bt_pick Paired "Forget" && bt_run "Removing $BT_MAC" "remove $BT_MAC" ;;
            back)       return ;;
        esac
    done
}

menu_info() {
    local ips ssh_state
    ips=$(hostname -I 2>/dev/null)
    ssh_state=$(systemctl is-active ssh.service 2>/dev/null)
    whiptail --title "Network / SSH" --msgbox \
        "IP address(es): ${ips:-none}\nSSH: ${ssh_state}\n\nFrom another computer:\n  ssh $(cat /etc/cn60/user 2>/dev/null)@<IP above>" 13 70
}

menu_tv_power() {
    local choice
    choice=$(whiptail --title "TV power (HDMI-CEC)" --menu "Control the TV" 12 60 3 \
        on   "Turn TV on" \
        off  "Put TV in standby" \
        back "Return" 3>&1 1>&2 2>&3) || return
    case "$choice" in
        on)  echo 'on 0'  | cec-client -s -d 1 >/dev/null 2>&1 && whiptail --msgbox "Sent power-on." 7 40 || whiptail --msgbox "CEC command failed. Check the HDMI cable and that CEC is enabled on the TV." 9 60 ;;
        off) echo 'standby 0' | cec-client -s -d 1 >/dev/null 2>&1 && whiptail --msgbox "Sent standby." 7 40 || whiptail --msgbox "CEC command failed." 7 40 ;;
        back) ;;
    esac
}

# TV tweaks (cn60-tweaks): hide phone apps, scaling, bottom bar, time zone.
tw_run() { clear; /usr/local/bin/cn60-tweaks "$@"; read -rp "Press Enter to continue " _; }

menu_tweaks() {
    local choice v
    while true; do
        choice=$(whiptail --title "TV tweaks" --menu "$(/usr/local/bin/cn60-tweaks status 2>&1 | head -n 4)" 21 74 8 \
            all      "Do all of the below (recommended for a TV)" \
            apps     "Hide phone apps (Clock, Contacts, Music, Camera...)" \
            restore  "Bring the hidden apps back" \
            scale    "Size of text and icons (scaling)" \
            navbar   "Hide or show the bottom bar" \
            timezone "Set Android's clock to this box's time zone" \
            back     "Return" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            all)      tw_run all ;;
            apps)     tw_run apps-remove ;;
            restore)  tw_run apps-restore ;;
            scale)    v=$(whiptail --title "Scaling" --menu "Bigger number = bigger text and icons" 17 64 7 \
                          auto  "Match the resolution (recommended)" \
                          160   "720p normal" \
                          240   "1080p normal" \
                          360   "4K small" \
                          480   "4K normal" \
                          560   "4K large" \
                          reset "Android default" 3>&1 1>&2 2>&3) && tw_run density "$v" ;;
            navbar)   v=$(whiptail --title "Bottom bar" --menu "Without the bar, use the remote's Back and Home keys. Android restarts." 12 64 2 \
                          off "Hide the bottom bar" \
                          on  "Show the bottom bar" 3>&1 1>&2 2>&3) && tw_run navbar "$v" ;;
            timezone) tw_run timezone ;;
            back)     return ;;
        esac
    done
}

while true; do
    status_line=$(cat /etc/cn60/status 2>/dev/null)
    choice=$(whiptail --title "CN60 Settings (script v$(cat /etc/cn60/version 2>/dev/null))" \
        --menu "${status_line:-Everything is up to date.}" 24 70 13 \
        resolution "Change display resolution" \
        tweaks     "TV tweaks: hide apps, scaling, bottom bar, clock" \
        bluetooth  "Bluetooth devices" \
        tv         "TV power on/off (CEC)" \
        info       "IP address and SSH" \
        remote     "See this screen on a PC (scrcpy)" \
        crashes    "Why do apps close? (crash report)" \
        apps       "Install Aurora Store (Google Play client)" \
        restart    "Restart the Android kiosk" \
        check      "Check for updates" \
        update     "Update script + Debian + Android now" \
        reboot     "Reboot the box" \
        exit       "Quit" 3>&1 1>&2 2>&3) || break
    case "$choice" in
        resolution) menu_resolution ;;
        tweaks)     menu_tweaks ;;
        bluetooth)  menu_bluetooth ;;
        tv)         menu_tv_power ;;
        info)       menu_info ;;
        remote)     clear; /usr/local/bin/cn60-remote; read -rp "Press Enter to return to the menu " _ ;;
        crashes)    clear; /usr/local/bin/cn60-crashlog | less -R; ;;
        apps)       if whiptail --yesno "Install Aurora Store?\n\nIt downloads apps from Google Play without Google's apps. Apps that need Google Play Services may not work." 11 64; then
                        clear; /usr/local/bin/cn60-apps aurora; read -rp "Press Enter to return to the menu " _
                    fi ;;
        restart)    systemctl restart waydroid-kiosk.service ;;
        check)      clear; /usr/local/bin/cn60-check --no-notify; read -rp "Press Enter to return to the menu " _ ;;
        update)     clear; /usr/local/bin/cn60-update; read -rp "Press Enter to return to the menu " _ ;;
        reboot)     whiptail --yesno "Reboot now?" 7 40 && systemctl reboot ;;
        exit)       break ;;
    esac
done
CN60_SETTINGS_EOF

    # TV tweaks: hide phone apps, UI scaling (DPI), bottom bar, Android time zone.
    put_file /usr/local/bin/cn60-tweaks 755 <<'CN60_TWEAKS_EOF'
#!/usr/bin/env bash
# CN60 TV tweaks for Android: hide stock phone apps, UI scaling (DPI), hide the bottom
# navigation bar, and set Android's time zone. Written by cn60-waydroid-setup.sh.
# Usage: sudo cn60-tweaks status|all|apps-remove|apps-restore|density <dpi|auto|reset>
#                         |navbar <off|on>|timezone [Area/City]
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo cn60-tweaks $*"; exit 1; }

CFG=/var/lib/waydroid/waydroid.cfg
BACKUP=/etc/cn60/backup
KUSER="$(cat /etc/cn60/user 2>/dev/null || echo tv)"
# Stock apps that make little sense on a TV. "pm uninstall --user 0" hides them for the
# user only: they stay in the Android image and "cn60-tweaks apps-restore" brings them back.
APPS=(com.android.deskclock:Clock com.android.contacts:Contacts org.lineageos.eleven:Music
      org.lineageos.recorder:Recorder com.android.calculator2:Calculator
      org.lineageos.etar:Calendar org.lineageos.aperture:Camera)

ash() { waydroid shell -- "$@" 2>&1 | tr -d '\r'; }

need_android() {
    if [[ $(waydroid status 2>/dev/null) != *Session:*RUNNING* ]]; then
        echo "Android is not running. Start it with: sudo systemctl restart waydroid-kiosk"
        echo "then wait a minute and try again."
        exit 1
    fi
}

# Read the package list once into a variable: "ash ... | grep -q" would race with
# pipefail (grep exits early, the writer gets SIGPIPE, the test randomly fails).
PKGS=""
load_pkgs() { PKGS=$(ash /system/bin/pm list packages); }
installed() { [[ $'\n'"$PKGS"$'\n' == *$'\n'"package:$1"$'\n'* ]]; }

apps_remove() {
    local e pkg name out
    load_pkgs
    for e in "${APPS[@]}"; do
        pkg=${e%%:*}; name=${e#*:}
        if installed "$pkg"; then
            out=$(ash /system/bin/pm uninstall --user 0 "$pkg")
            [[ $out == *Success* ]] && echo "  hidden: $name" || echo "  FAILED: $name ($out)"
        else
            echo "  already hidden: $name"
        fi
    done
}

apps_restore() {
    local e pkg name out
    load_pkgs
    for e in "${APPS[@]}"; do
        pkg=${e%%:*}; name=${e#*:}
        if installed "$pkg"; then echo "  already there: $name"; continue; fi
        out=$(ash /system/bin/pm install-existing --user 0 "$pkg")
        [[ $out == *installed* || $out == *Success* ]] && echo "  restored: $name" || echo "  FAILED: $name ($out)"
    done
}

# Density that gives a 1280x720-sized layout (about right from a sofa) at the configured
# resolution: 4K -> 480, 1080p -> 240, 720p -> 160.
auto_dpi() {
    local HEIGHT=1080
    # shellcheck disable=SC1091
    [[ -r /etc/cn60/display.conf ]] && . /etc/cn60/display.conf
    echo $(( ${HEIGHT:-1080} * 2 / 9 ))
}

density() {
    local v=${1:-auto}
    [[ $v == auto ]] && v=$(auto_dpi)
    if [[ $v == reset ]]; then
        ash /system/bin/wm density reset >/dev/null
        echo "  scaling: Android default"
    elif [[ $v =~ ^[0-9]+$ ]] && (( v >= 100 && v <= 800 )); then
        ash /system/bin/wm density "$v" >/dev/null
        echo "  scaling: $v dpi"
    else
        echo "Density must be a number from 100 to 800, 'auto' or 'reset'."; return 1
    fi
}

# After a resolution change: keep the layout size, but only if a density was chosen before.
density_follow() {
    [[ $(ash /system/bin/wm density) == *'Override density'* ]] && density auto
    return 0
}

# The bottom bar is hidden with the qemu.hw.mainkeys=1 property ("this device has hardware
# keys"). It lives in waydroid.cfg [properties], so it survives "waydroid upgrade".
navbar() {
    local want=$1 out
    [[ $want == off || $want == on ]] || { echo "Use: cn60-tweaks navbar off|on"; return 1; }
    [[ -f $CFG ]] || { echo "$CFG missing; is Waydroid installed?"; return 1; }
    out="$(python3 - "$CFG" "$want" <<'PY'
import configparser, sys
path, want = sys.argv[1], sys.argv[2]
c = configparser.ConfigParser()
c.read(path)
if not c.has_section("properties"):
    c.add_section("properties")
cur = c.get("properties", "qemu.hw.mainkeys", fallback=None)
if want == "off" and cur != "1":
    c.set("properties", "qemu.hw.mainkeys", "1")
elif want == "on" and cur is not None:
    c.remove_option("properties", "qemu.hw.mainkeys")
else:
    sys.exit(0)
with open(path + ".cn60new", "w") as f:
    c.write(f)
print("changed")
PY
)" || { rm -f "$CFG.cn60new"; echo "Could not edit $CFG."; return 1; }
    if [[ $out != changed ]]; then
        echo "  bottom bar: already $want"; return 0
    fi
    local b="$BACKUP$CFG"
    [[ -e $b ]] || { mkdir -p "$(dirname "$b")"; cp -a "$CFG" "$b"; }
    mv -f "$CFG.cn60new" "$CFG"
    echo "  bottom bar: $want (restarting Android, about a minute)"
    # Android saves app changes (hidden apps) about 10 s after they are made; stopping it
    # sooner loses them. Give it time if it is running.
    [[ $(waydroid status 2>/dev/null) == *Session:*RUNNING* ]] && sleep 15
    systemctl stop waydroid-kiosk.service 2>/dev/null || true
    runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
    waydroid upgrade --offline >/dev/null 2>&1 || echo "  WARNING: waydroid upgrade --offline failed"
    systemctl restart waydroid-container.service
    systemctl start waydroid-kiosk.service
}

timezone() {
    local tz=${1:-}
    [[ -n $tz ]] || tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [[ -n $tz ]] || tz=$(cat /etc/timezone 2>/dev/null)
    if [[ -z $tz || ! -f /usr/share/zoneinfo/$tz ]]; then
        echo "Unknown time zone '${tz}'. Example: cn60-tweaks timezone America/New_York"; return 1
    fi
    ash /system/bin/settings put global auto_time_zone 0 >/dev/null
    ash /system/bin/cmd alarm set-timezone "$tz" >/dev/null
    if [[ $(ash /system/bin/getprop persist.sys.timezone) == "$tz" ]]; then
        echo "  time zone: $tz (Android now shows $(ash /system/bin/date '+%H:%M'))"
    else
        echo "  FAILED to set the time zone to $tz"; return 1
    fi
}

status() {
    local e hidden=() d mk tz
    load_pkgs
    for e in "${APPS[@]}"; do installed "${e%%:*}" || hidden+=("${e#*:}"); done
    d=$(ash /system/bin/wm density | sed -n 's/Override density: //p')
    mk=$(ash /system/bin/getprop qemu.hw.mainkeys)
    tz=$(ash /system/bin/getprop persist.sys.timezone)
    echo "Hidden apps: ${hidden[*]:-none}"
    echo "Scaling:     ${d:-Android default} dpi (suggested $(auto_dpi))"
    echo "Bottom bar:  $([[ $mk == 1 ]] && echo hidden || echo shown)"
    echo "Time zone:   ${tz:-unset} (box: $(timedatectl show -p Timezone --value 2>/dev/null))"
}

cmd=${1:-help}; shift || true
case $cmd in
    status)        need_android; status ;;
    apps-remove)   need_android; apps_remove ;;
    apps-restore)  need_android; apps_restore ;;
    density)       need_android; density "${1:-auto}" ;;
    density-follow) need_android; density_follow ;;
    timezone)      need_android; timezone "${1:-}" ;;
    navbar)        navbar "${1:-}" ;;
    all)           need_android
                   apps_remove; density auto; timezone; navbar off ;;
    *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
CN60_TWEAKS_EOF

    # Keep a copy of this script on the box, for self-update and uninstall from anywhere.
    put_file /usr/local/lib/cn60/cn60-waydroid-setup.sh 755 < "$SELF"

    # Update checker: new script version on GitHub + pending Debian updates -> Android notification.
    put_file /usr/local/bin/cn60-check 755 <<'CN60_CHECK_EOF'
#!/usr/bin/env bash
# CN60 update check: new setup-script version on GitHub, pending Debian updates,
# pending reboot. Writes /etc/cn60/status and posts an Android notification.
#   sudo cn60-check               check, print the result, notify in Android
#   sudo cn60-check --quiet       no output (used by the daily timer)
#   sudo cn60-check --no-notify   do not post an Android notification
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo cn60-check"; exit 1; }
QUIET=0; WANT_NOTIFY=1
for a in "$@"; do
    case "$a" in --quiet) QUIET=1 ;; --no-notify) WANT_NOTIFY=0 ;; esac
done
say() { [[ $QUIET -eq 1 ]] || echo "$*"; }

REPO=carongutermuth113/cn60-waydroid-kiosk; BRANCH=main; GITHUB_TOKEN=""; NOTIFY=yes
# shellcheck disable=SC1091
[[ -r /etc/cn60/update.conf ]] && . /etc/cn60/update.conf
LIB=/var/lib/cn60
mkdir -p "$LIB"
installed="$(cat /etc/cn60/version 2>/dev/null || echo 0)"

# Apps queued while Android was not running (for example Aurora Store on a fresh install).
if [[ -s /etc/cn60/pending-apps && -x /usr/local/bin/cn60-apps ]]; then
    /usr/local/bin/cn60-apps pending >/dev/null 2>&1 || true
fi

# 1. Newest setup script on GitHub (API works for public repos, and private ones with a token).
latest=""
tmp="$(mktemp)"
hdr=(-H "Accept: application/vnd.github.raw")
[[ -n $GITHUB_TOKEN ]] && hdr+=(-H "Authorization: Bearer $GITHUB_TOKEN")
code="$(curl -sL --max-time 60 "${hdr[@]}" -o "$tmp" -w '%{http_code}' \
        "https://api.github.com/repos/$REPO/contents/cn60-waydroid-setup.sh?ref=$BRANCH" || true)"
gh_problem=""
case "$code" in
    200) if bash -n "$tmp" 2>/dev/null; then
             latest="$(sed -n 's/^SCRIPT_VERSION=\([0-9][0-9]*\).*/\1/p' "$tmp" | head -n1)"
         else
             gh_problem="the downloaded script has syntax errors; not using it."
         fi ;;
    404) if [[ -z $GITHUB_TOKEN ]]; then
             gh_problem="the repo $REPO is private (or does not exist). Make it public, or put a read-only token after GITHUB_TOKEN= in /etc/cn60/update.conf."
         else
             gh_problem="$REPO or branch $BRANCH not found, or the token cannot read this repo (it needs Contents: Read-only on $REPO)."
         fi ;;
    401) gh_problem="the GITHUB_TOKEN in /etc/cn60/update.conf is wrong or expired. Make a new one." ;;
    403|429) gh_problem="GitHub refused or rate-limited the request; it will retry at the next check." ;;
    000|"") gh_problem="no connection to github.com (check the network/DNS)." ;;
    *)   gh_problem="GitHub answered HTTP $code." ;;
esac
script_new=0
if [[ $latest =~ ^[0-9]+$ && $installed =~ ^[0-9]+$ ]] && (( latest > installed )); then
    script_new=1
    install -m 700 "$tmp" "$LIB/latest-setup.sh"
fi
rm -f "$tmp"
[[ -n $latest ]] || say "Script update check skipped: ${gh_problem:-could not read the version.}"

# 2. Pending Debian updates.
apt-get -qq -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1 || true
debs="$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true)"

# 3. New kernel waiting for a reboot.
newest="$(ls -1 /lib/modules | sort -V | tail -n1)"
reboot_needed=0
[[ -n $newest && $newest != "$(uname -r)" ]] && reboot_needed=1

msg=""
(( script_new )) && msg+="CN60 script v$latest is available (installed: v$installed). "
(( debs > 0 )) && msg+="$debs Debian update(s) waiting. "
(( reboot_needed )) && msg+="Reboot needed for the new kernel. "
printf 'LATEST=%s\nINSTALLED=%s\nDEBIAN_UPDATES=%s\nREBOOT=%s\nCHECKED=%s\n' \
    "${latest:-unknown}" "$installed" "$debs" "$reboot_needed" "$(date '+%F %R')" > "$LIB/check.env"

if [[ -z $msg ]]; then
    rm -f /etc/cn60/status
    if [[ -n $latest ]]; then say "Everything is up to date (script v$installed)."
    else say "No Debian updates waiting. (Script version not checked, see above.)"; fi
    exit 0
fi
echo "$msg" > /etc/cn60/status
say "$msg"
say "Install now: sudo cn60-update (or Settings > update). The weekly update runs Sundays at 04:30."

# 4. Android notification (best effort; needs the Waydroid container running).
android_notify() {
    local title=$1 text=$2
    waydroid status 2>/dev/null | grep -q 'Container:.*RUNNING' || return 1
    waydroid shell -- /system/bin/cmd notification post -S bigtext -t "$title" cn60-update "$text" \
        >/dev/null 2>&1 && return 0
    printf "cmd notification post -S bigtext -t '%s' cn60-update '%s'\nexit\n" "$title" "$text" \
        | waydroid shell >/dev/null 2>&1
}
if [[ $WANT_NOTIFY -eq 1 && $NOTIFY == yes ]]; then
    if android_notify "CN60 updates available" \
        "${msg}They install automatically on Sunday at 04:30, or open Settings > update on Ctrl+Alt+F2."; then
        say "Android notification sent."
    else
        say "Could not post the Android notification (is Android running?)."
    fi
fi
exit 0
CN60_CHECK_EOF

    # Remote screen: lets a PC see and control Android with scrcpy through an SSH tunnel.
    put_file /usr/local/bin/cn60-remote 755 <<'CN60_REMOTE_EOF'
#!/usr/bin/env bash
# CN60 remote screen helper: see and control Android from a PC with scrcpy over SSH.
# ADB is never opened to the network; the PC reaches it only through an SSH tunnel.
#   cn60-remote          show status and the commands to run on your PC
#   sudo cn60-remote     same, and turn on network ADB inside Android if it is off
#   cn60-remote --ip     print only Android's internal IP (used by the Windows helper)
set -uo pipefail
ip="$(waydroid status 2>/dev/null | sed -n 's/^IP address:[[:space:]]*//p' | head -n1)"
ip="${ip:-192.168.240.112}"
if [[ ${1:-} == --ip ]]; then echo "$ip"; exit 0; fi

port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$ip/5555" 2>/dev/null; }
if ! port_open && [[ $EUID -eq 0 ]]; then
    echo "Turning on network ADB inside Android..."
    waydroid shell -- /system/bin/setprop service.adb.tcp.port 5555 >/dev/null 2>&1
    waydroid shell -- /system/bin/stop adbd >/dev/null 2>&1
    waydroid shell -- /system/bin/start adbd >/dev/null 2>&1
    sleep 3
fi
if port_open; then
    state="ready"
else
    state="NOT reachable. Is Android running? Try: sudo cn60-remote"
fi
box_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
user="$(cat /etc/cn60/user 2>/dev/null || id -un)"
cat <<EOF
Android ADB ($ip:5555): $state

On your PC (Windows: double-click windows\cn60-screen.bat from the GitHub repo), or by hand:
  1. ssh -N -L 15555:$ip:5555 $user@${box_ip:-<box-ip>}     (leave it open)
  2. adb connect 127.0.0.1:15555
  3. scrcpy -s 127.0.0.1:15555 --no-audio

The first time, the TV may ask "Allow USB debugging?": tick "Always allow" and press Allow.
EOF
CN60_REMOTE_EOF

    # Android app installer (Aurora Store); queues installs while Android is not running.
    put_file /usr/local/bin/cn60-apps 755 <<'CN60_APPS_EOF'
#!/usr/bin/env bash
# CN60 Android app installer.
#   sudo cn60-apps aurora           install Aurora Store (Google Play client) from F-Droid
#   sudo cn60-apps at4k             install/update AT4K Launcher (Android TV launcher) from its GitHub releases
#   sudo cn60-apps install <apk>    install an .apk file or https:// link (apps Aurora calls "not supported")
#   sudo cn60-apps pending          install apps that were queued while Android was not running
#   sudo cn60-apps list             list installed Android apps
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo cn60-apps $*"; exit 1; }
PENDING=/etc/cn60/pending-apps
KUSER="$(cat /etc/cn60/user)"
UIDN="$(id -u "$KUSER")"
as_user() { runuser -u "$KUSER" -- env XDG_RUNTIME_DIR="/run/user/$UIDN" "$@"; }
android_up() { waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; }
has_pkg() { as_user waydroid app list 2>/dev/null | grep -q "packageName: $1\$"; }
queue() {
    grep -qx "$1" "$PENDING" 2>/dev/null || echo "$1" >> "$PENDING"
    echo "Android is not running. $2 is queued and installs automatically once it is (15 min after boot, then daily)."
}
unqueue() {
    [[ -f $PENDING ]] || return 0
    sed -i "/^$1\$/d" "$PENDING"
    [[ -s $PENDING ]] || rm -f "$PENDING"
}

# install_fdroid <queue key> <display name> <package id>: newest suggested build from f-droid.org
install_fdroid() {
    local key=$1 name=$2 pkg=$3 code tmp
    if ! android_up; then queue "$key" "$name"; return 0; fi
    if has_pkg "$pkg"; then
        echo "$name is already installed (it updates itself)."
        unqueue "$key"; return 0
    fi
    code="$(curl -fsSL --max-time 30 "https://f-droid.org/api/v1/packages/$pkg" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["suggestedVersionCode"])' 2>/dev/null)"
    [[ $code =~ ^[0-9]+$ ]] || { echo "Could not get $name's version from F-Droid."; return 1; }
    tmp="$(mktemp --suffix=.apk)"
    echo "Downloading $name (F-Droid build $code)..."
    if ! curl -fL --max-time 600 -o "$tmp" "https://f-droid.org/repo/${pkg}_${code}.apk" \
       || [[ "$(head -c2 "$tmp")" != PK ]]; then
        rm -f "$tmp"; echo "Download of $name failed."; return 1
    fi
    local rc=0
    put_apk "$tmp" "$name" "$pkg" || rc=1
    rm -f "$tmp"
    [[ $rc -eq 0 ]] && unqueue "$key"
    return $rc
}

# put_apk <apk file> <display name> [package id]: install (or update) an APK in Android.
# Android does not check Play Store "compatibility" (TV-only, tablet-only), only the APK itself.
put_apk() {
    local apk=$1 name=$2 pkg=${3:-} tmp rc=0
    if [[ "$(head -c2 "$apk" 2>/dev/null)" != PK ]]; then
        echo "$apk is not an APK file."; return 1
    fi
    # Copy to a file the kiosk user can read; the original may sit in a private folder.
    tmp="$(mktemp --suffix=.apk)"
    cp "$apk" "$tmp" && chmod 644 "$tmp"
    echo "Installing $name in Android..."
    as_user waydroid app install "$tmp" || rc=1
    rm -f "$tmp"
    if [[ $rc -ne 0 ]]; then
        echo "Install of $name failed. Split APKs (.apks, .xapk, .apkm bundles) are not supported; use a single .apk."
        return 1
    fi
    sleep 3
    if [[ -z $pkg ]] || has_pkg "$pkg"; then
        echo "$name installed. Open it from the Android app drawer."
    else
        echo "$name was sent to Android but does not show up yet; check the TV screen."
    fi
}

# install_github <queue key> <display name> <package id> <owner/repo>: newest release .apk
install_github() {
    local key=$1 name=$2 pkg=$3 repo=$4 url tmp
    if ! android_up; then queue "$key" "$name"; return 0; fi
    url="$(curl -fsSL --max-time 30 "https://api.github.com/repos/$repo/releases/latest" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin); print(next(a["browser_download_url"] for a in r["assets"] if a["name"].endswith(".apk")))' 2>/dev/null)"
    [[ $url == https://* ]] || { echo "Could not find $name's newest release on GitHub ($repo)."; return 1; }
    tmp="$(mktemp --suffix=.apk)"
    echo "Downloading $name from $url ..."
    if ! curl -fL --max-time 600 -o "$tmp" "$url"; then
        rm -f "$tmp"; echo "Download of $name failed."; return 1
    fi
    local rc=0
    put_apk "$tmp" "$name" "$pkg" || rc=1
    rm -f "$tmp"
    [[ $rc -eq 0 ]] && unqueue "$key"
    return $rc
}

# install_any <file.apk | https://...>: sideload any single APK.
install_any() {
    local src=${1:-} tmp rc
    [[ -n $src ]] || { echo "Usage: sudo cn60-apps install <file.apk | https://link-to.apk>"; return 1; }
    android_up || { echo "Android is not running. Start it first (it runs on the TV screen), then try again."; return 1; }
    if [[ $src == https://* ]]; then
        tmp="$(mktemp --suffix=.apk)"
        echo "Downloading $src ..."
        curl -fL --max-time 600 -o "$tmp" "$src" || { rm -f "$tmp"; echo "Download failed."; return 1; }
        put_apk "$tmp" "$(basename "${src%%\?*}")"; rc=$?
        rm -f "$tmp"; return $rc
    fi
    [[ -f $src ]] || { echo "File not found: $src"; return 1; }
    put_apk "$src" "$(basename "$src")"
}

case "${1:-}" in
    aurora)  install_fdroid aurora "Aurora Store" com.aurora.store ;;
    at4k)    install_github at4k "AT4K Launcher" com.overdevs.at4k avadhesh18/at4k ;;
    install) install_any "${2:-}" ;;
    pending)
        [[ -s $PENDING ]] || exit 0
        android_up || exit 0
        rc=0
        while read -r app; do
            case "$app" in
                aurora) install_fdroid aurora "Aurora Store" com.aurora.store || rc=1 ;;
                at4k)   install_github at4k "AT4K Launcher" com.overdevs.at4k avadhesh18/at4k || rc=1 ;;
            esac
        done < <(cat "$PENDING")
        exit $rc ;;
    list)    as_user waydroid app list ;;
    *)       sed -n '2,7p' "$0"; exit 1 ;;
esac
CN60_APPS_EOF

    # Crash report: tells in plain words why Android apps close.
    put_file /usr/local/bin/cn60-crashlog 755 <<'CN60_CRASHLOG_EOF'
#!/usr/bin/env bash
# CN60 crash report: why do Android apps crash or close?
#   sudo cn60-crashlog          show the report and save it to /var/log/cn60-crash-report.txt
#   sudo cn60-crashlog --clear  empty Android's crash log; then open the app that crashes and
#                               run sudo cn60-crashlog again, so only that crash is shown
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo cn60-crashlog"; exit 1; }
OUT=/var/log/cn60-crash-report.txt
ash() { timeout 30 waydroid shell -- "$@" 2>/dev/null; }
android_up=0
waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING' && android_up=1

if [[ ${1:-} == --clear ]]; then
    [[ $android_up -eq 1 ]] || { echo "Android is not running."; exit 1; }
    ash /system/bin/logcat -c -b all
    echo "Crash log cleared. Now open the app that crashes, then run: sudo cn60-crashlog"
    exit 0
fi

report="$(
    echo "CN60 crash report, $(date '+%F %T')"
    echo; echo "== Debian memory"
    free -h; swapon --show
    echo "memory pressure: $(head -n1 /proc/pressure/memory 2>/dev/null)"
    echo; echo "== Debian out-of-memory kills (this boot)"
    # Real kernel OOM kills only (Android's "libprocessgroup: Successfully killed" lines are normal app exits).
    ooms="$(journalctl -k -b --no-pager 2>/dev/null | grep -E 'Out of memory: Killed process|oom-kill:|invoked oom-killer' \
            | grep -v libprocessgroup | tail -n 15)"
    echo "${ooms:-none}"
    if [[ $android_up -eq 1 ]]; then
        echo; echo "== Android settings"
        for p in ro.product.cpu.abilist ro.dalvik.vm.native.bridge dalvik.vm.heapgrowthlimit \
                 dalvik.vm.heapsize persist.waydroid.width persist.waydroid.height; do
            echo "$p=$(ash /system/bin/getprop "$p" | tr -d '\r')"
        done
        echo; echo "== Android low-memory kills (last 20)"
        ash /system/bin/logcat -d -b main,system,events | tr -d '\r' \
            | grep -iE 'lowmemorykiller|lmkd.*kill|am_kill' | tail -n 20
        echo; echo "== App crashes (newest last)"
        ash /system/bin/logcat -d -b crash | tr -d '\r' | tail -n 150
    else
        echo; echo "Android is not running, so its crash log cannot be read."
    fi
)"

# Plain-language hints from the report (the settings section is left out of the matching).
src="$(sed '/^== Android settings/,/^== Android low-memory/d' <<< "$report")"
hints=()
if [[ $android_up -eq 1 ]] && grep -qE '^ro\.dalvik\.vm\.native\.bridge=(0)?$' <<< "$report"; then
    hints+=("ARM translation is not active, so ARM-only apps cannot start. Re-run: sudo /usr/local/lib/cn60/cn60-waydroid-setup.sh --force")
fi
grep -qiE 'com\.google\.android\.gms|GooglePlayServices|play services' <<< "$src" && \
    hints+=("An app needs Google Play Services, which the VANILLA Android image does not have. Such apps (YouTube, Netflix, Google apps, many games) close right after opening. Fixing this needs a different Android image (GApps or microG).")
grep -qiE 'UnsatisfiedLinkError|couldn.t find "lib|dlopen failed|libhoudini|libndk' <<< "$src" && \
    hints+=("An app has ARM-only code that did not load: ARM translation is missing or failing. Re-run: sudo /usr/local/lib/cn60/cn60-waydroid-setup.sh --force")
grep -qi 'OutOfMemoryError' <<< "$src" && \
    hints+=("An app ran out of its Java memory limit (OutOfMemoryError).")
grep -qiE 'lowmemorykiller|am_kill' <<< "$src" && \
    hints+=("Android closed apps because RAM was full. Use 1080p instead of 4K (Settings > resolution) and keep few apps open.")
grep -qE 'Out of memory: Killed process|oom-kill:' <<< "$src" && \
    hints+=("Debian ran out of memory and killed processes. Check that swap is on (the 'Debian memory' section above should list zram and /cn60.swap).")
grep -qiE 'libEGL|libGLES|gralloc|mesa|iris|i965|SIGSEGV' <<< "$src" && \
    hints+=("A native crash (possibly graphics/GPU). Send this report for a closer look.")

if grep -q 'was already used. If you are using LazyColumn' <<< "$src" && grep -q 'com.aurora.store' <<< "$src"; then
    hints+=("Aurora Store bug: its home feed lists the same app twice and it crashes (Aurora issue #1611, https://gitlab.com/AuroraOSS/AuroraStore/-/issues/1611). Not the box. Workaround: open Aurora and tap Search right away, before the home screen loads. A later Aurora version should fix it.")
fi
if [[ ${#hints[@]} -eq 0 ]] && grep -q 'FATAL EXCEPTION' <<< "$src"; then
    app="$(grep -m1 -o 'Process: [^,]*' <<< "$src" | cut -d' ' -f2)"
    exc="$(grep -A2 'FATAL EXCEPTION' <<< "$src" | grep -m1 -oE '[a-zA-Z0-9_.]+(Exception|Error)[^:]*(: .{0,120})?')"
    hints+=("${app:-An app} crashed because of a bug in the app itself (${exc:-Java exception}). Memory, ARM translation and Play Services are not the cause. Look for an app update or report it to the app's developer.")
fi

{
    echo "$report"
    echo; echo "== What this probably means"
    if [[ ${#hints[@]} -eq 0 ]]; then
        echo "- No known cause found. Run 'sudo cn60-crashlog --clear', open the app until it crashes, then run 'sudo cn60-crashlog' again."
    else
        printf -- '- %s\n' "${hints[@]}"
    fi
    echo; echo "Saved to $OUT"
} | tee "$OUT"
CN60_CRASHLOG_EOF

    # Shown when you log in over SSH or on a console.
    put_file /etc/update-motd.d/90-cn60 755 <<'EOF'
#!/bin/sh
[ -s /etc/cn60/status ] && printf '\nCN60: %s\nRun: sudo cn60-update\n\n' "$(cat /etc/cn60/status)"
exit 0
EOF

    # Updater: used by the weekly timer, the settings menu, and this script.
    put_file /usr/local/bin/cn60-update 755 <<'CN60_UPDATE_EOF'
#!/usr/bin/env bash
# CN60 updater: upgrades Debian packages and the Waydroid Android image.
#   sudo cn60-update                   update the CN60 script from GitHub, upgrade Debian and
#                                      Android, restart the kiosk if it was running
#   sudo cn60-update --no-restart      leave the kiosk stopped (used by the setup script)
#   sudo cn60-update --no-self-update  skip the GitHub script update
#   sudo cn60-update --auto            weekly timer: follows AUTO_APPLY_SCRIPT and reboots
#                                      if a new kernel was installed
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo cn60-update"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
RESTART=1; AUTO=0; SELF_UPDATE=1
for a in "$@"; do
    case "$a" in
        --no-restart) RESTART=0 ;; --auto) AUTO=1 ;; --no-self-update) SELF_UPDATE=0 ;;
    esac
done
AUTO_APPLY_SCRIPT=yes
# shellcheck disable=SC1091
[[ -r /etc/cn60/update.conf ]] && . /etc/cn60/update.conf
rc=0

if [[ $SELF_UPDATE -eq 1 ]]; then
    echo "==> Checking GitHub for a new CN60 setup script"
    /usr/local/bin/cn60-check --no-notify | grep -i 'script\|github' || true
    new="$(sed -n 's/^SCRIPT_VERSION=\([0-9][0-9]*\).*/\1/p' /var/lib/cn60/latest-setup.sh 2>/dev/null | head -n1)"
    cur="$(cat /etc/cn60/version 2>/dev/null || echo 0)"
    if [[ $new =~ ^[0-9]+$ && $cur =~ ^[0-9]+$ ]] && (( new > cur )); then
        if [[ $AUTO -eq 0 || $AUTO_APPLY_SCRIPT == yes ]]; then
            echo "==> Installing CN60 setup script v$new (was v$cur)"
            bash /var/lib/cn60/latest-setup.sh --no-upgrade || { echo "Script update failed."; rc=1; }
        else
            echo "Script v$new is available; AUTO_APPLY_SCRIPT=no, so it was not installed."
        fi
    fi
fi

echo "==> Upgrading Debian packages"
"${APT[@]}" update || rc=1
"${APT[@]}" full-upgrade || rc=1
"${APT[@]}" autoremove --purge || true
"${APT[@]}" autoclean || true

echo "==> Upgrading the Waydroid Android image"
was_active=0
if systemctl is-active --quiet waydroid-kiosk.service; then
    was_active=1
    systemctl stop waydroid-kiosk.service
fi
KUSER="$(cat /etc/cn60/user 2>/dev/null || true)"
[[ -n $KUSER ]] && runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
waydroid upgrade || { echo "Waydroid upgrade failed; Android keeps its current image."; rc=1; }

newest="$(ls -1 /lib/modules | sort -V | tail -n1)"
if [[ -n $newest && $newest != "$(uname -r)" ]]; then
    echo "New kernel $newest installed. Reboot to use it: sudo reboot"
    if [[ $AUTO -eq 1 ]]; then systemctl reboot; exit $rc; fi
fi
if [[ $was_active -eq 1 && $RESTART -eq 1 ]]; then
    systemctl start waydroid-kiosk.service
fi
/usr/local/bin/cn60-check --quiet || true   # refresh status; notify if something is still pending
[[ $rc -eq 0 ]] && echo "Update finished." || echo "Update finished with errors (see above)."
exit $rc
CN60_UPDATE_EOF

    # Runs as root: sets resolution, powers on the TV, then hands off to the user.
    put_file /usr/local/bin/cn60-kiosk-start 755 <<'EOF'
#!/bin/sh
# Root part of the kiosk: wake the TV, start the user session.
KUSER="$(cat /etc/cn60/user)"
UID_NUM="$(id -u "$KUSER")"

# Resolution is applied by cn60-kiosk-user: waydroid prop set only works while Android runs.
echo 'on 0' | timeout 10 cec-client -s -d 1 >/dev/null 2>&1 || true   # best effort, never blocks boot

systemctl start "user@${UID_NUM}.service" || true
exec runuser -u "$KUSER" -- env XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" \
    cage -s -- /usr/local/bin/cn60-kiosk-user
EOF

    # Runs as the normal user inside cage: start Waydroid and show it fullscreen.
    put_file /usr/local/bin/cn60-kiosk-user 755 <<'EOF'
#!/bin/sh
# Start Android, wait until it is really up (slow with 4 GB RAM), apply the resolution from
# /etc/cn60/display.conf, then show Android fullscreen.
CONF=/etc/cn60/display.conf
[ -r "$CONF" ] && . "$CONF"
WIDTH="${WIDTH:-1920}"; HEIGHT="${HEIGHT:-1080}"
wait_up() {
    i=0
    while [ "$i" -lt 120 ]; do
        waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING' && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}
start_android() {
    waydroid session stop >/dev/null 2>&1 || true
    waydroid session start >/dev/null 2>&1 &
    wait_up
}
start_android
# Resolution props can only be set while Android runs, and apply at its next start:
# if they differ, set them and restart Android once.
if [ "$(waydroid prop get persist.waydroid.width 2>/dev/null)" != "$WIDTH" ] ||
   [ "$(waydroid prop get persist.waydroid.height 2>/dev/null)" != "$HEIGHT" ]; then
    waydroid prop set persist.waydroid.width "$WIDTH" &&
        waydroid prop set persist.waydroid.height "$HEIGHT" && start_android
fi
exec waydroid show-full-ui
EOF

    put_file /etc/systemd/system/waydroid-kiosk.service 644 <<'EOF'
[Unit]
Description=CN60 Waydroid fullscreen kiosk
After=waydroid-container.service seatd.service systemd-user-sessions.service network.target
Wants=waydroid-container.service seatd.service systemd-user-sessions.service
Conflicts=getty@tty1.service
OnFailure=cn60-fallback.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
ExecStart=/usr/local/bin/cn60-kiosk-start
# If Android's screen closes for any reason, bring it straight back.
Restart=always
RestartSec=3
# Debian's OOM killer should pick something else before the kiosk screen.
OOMScoreAdjust=-500

[Install]
WantedBy=graphical-kiosk.target
EOF

    # If the kiosk gives up, bring back a text login on tty1 so the box is not dead.
    put_file /etc/systemd/system/cn60-fallback.service 644 <<'EOF'
[Unit]
Description=CN60 kiosk failed: restore text login on tty1

[Service]
Type=oneshot
ExecStart=/bin/systemctl start getty@tty1.service
EOF

    put_file /etc/systemd/system/graphical-kiosk.target 644 <<'EOF'
[Unit]
Description=Boot target for the CN60 Waydroid kiosk
# Pull in the normal system first (network, SSH, user logins), like graphical.target does.
# Without this, /run/nologin is never removed and only root can log in.
Requires=multi-user.target
Wants=waydroid-kiosk.service
After=multi-user.target waydroid-kiosk.service
AllowIsolate=yes
EOF

    put_file /etc/systemd/system/cn60-update.service 644 <<'EOF'
[Unit]
Description=CN60 weekly update (Debian + Waydroid image)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cn60-update --auto
EOF

    put_file /etc/systemd/system/cn60-update.timer 644 <<'EOF'
[Unit]
Description=Run the CN60 update every Sunday at 04:30

[Timer]
OnCalendar=Sun *-*-* 04:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    put_file /etc/systemd/system/cn60-check.service 644 <<'EOF'
[Unit]
Description=CN60 update check (GitHub script version + Debian updates)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cn60-check --quiet
EOF

    put_file /etc/systemd/system/cn60-check.timer 644 <<'EOF'
[Unit]
Description=Check for CN60 updates daily and 15 minutes after boot

[Timer]
OnBootSec=15min
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

do_install() {
    check_platform
    # Earlier versions booted without systemd-user-sessions, leaving /run/nologin behind.
    systemctl start systemd-user-sessions.service 2>/dev/null || true
    local kiosk_was_active=0 prev="none"
    systemctl is-active --quiet waydroid-kiosk.service 2>/dev/null && kiosk_was_active=1
    [[ -r $STATE/version ]] && prev="$(cat "$STATE/version")"
    if [[ -f $MARK ]]; then
        log "Already installed (version $prev). Script version $SCRIPT_VERSION: adding only what is new."
    fi

    # Questions first, so the rest can run unattended.
    ask_options

    # Always-checked steps: each one is idempotent and only changes what is missing.
    install_packages
    [[ $UPGRADE -eq 1 ]] && upgrade_debian
    ensure_user_groups
    ensure_binder
    write_config
    setup_waydroid
    write_helpers
    tune_memory

    # One-time steps: bump the number to make an existing install run the step again.
    log "Checking one-time steps"
    run_step arm-translation 2 install_arm_translation
    run_step os-tuning       1 tune_os
    run_step auto-updates    1 setup_auto_updates
    run_step ssh             1 setup_ssh
    run_step self-update     1 setup_self_update
    run_step network-clash   1 fix_network_clash
    run_step bt-audio        1 fix_bt_audio

    # After ARM translation: both edit waydroid.cfg [properties].
    tune_android

    if [[ $UPGRADE -eq 1 ]]; then
        log "Upgrading the Waydroid Android image"
        /usr/local/bin/cn60-update --no-restart --no-self-update >/dev/null 2>&1 \
            && echo "  done" || warn "Android image upgrade failed; run 'sudo cn60-update' to see why."
    fi

    if [[ "$(opt_get AURORA_STORE)" == yes ]]; then
        log "Checking Aurora Store"
        /usr/local/bin/cn60-apps aurora || warn "Aurora Store install failed; retry with: sudo cn60-apps aurora"
    fi

    log "Checking the boot target"
    systemctl enable --now seatd.service
    systemctl disable --now display-manager.service 2>/dev/null || true
    systemctl enable waydroid-kiosk.service
    systemctl set-default graphical-kiosk.target

    touch "$MARK"
    echo "$SCRIPT_VERSION" > "$STATE/version"
    /usr/local/bin/cn60-check --quiet --no-notify || true   # refresh the update status

    if [[ $kiosk_was_active -eq 1 ]]; then
        log "Restarting the kiosk to apply changes"
        systemctl restart waydroid-kiosk.service || warn "Kiosk restart failed: journalctl -u waydroid-kiosk -b"
    fi

    echo
    if [[ ${#CHANGES[@]} -eq 0 ]]; then
        echo "Nothing new to add. Everything is up to date."
    else
        echo "Changes this run:"
        printf '  - %s\n' "${CHANGES[@]}"
    fi
    newest="$(ls -1 /lib/modules | sort -V | tail -n1)"
    [[ -n $newest && $newest != "$(uname -r)" ]] && echo "A new kernel ($newest) is installed: reboot to use it."

    local ips
    ips="$(hostname -I 2>/dev/null | xargs || true)"
    cat <<EOM

SSH from another computer:  ssh $KUSER@${ips%% *}     (all addresses: ${ips:-unknown})

Next steps:
  - Test without rebooting:   sudo systemctl start waydroid-kiosk
  - Watch the logs:           journalctl -u waydroid-kiosk -b -f
  - Settings menu:            Ctrl+Alt+F2, log in, run: sudo cn60-settings
  - Update now:               sudo cn60-update
  - Check for updates:        sudo cn60-check
  - See the screen on a PC:   sudo cn60-remote
  - Why do apps close?        sudo cn60-crashlog
  - Install Aurora Store:     sudo cn60-apps aurora
  - Self-update settings:     sudo nano /etc/cn60/update.conf
  - Weekly auto-update:       systemctl list-timers cn60-update.timer
  - Reboot to start the kiosk (and apply boot tweaks).
  - Revert to a normal boot:  sudo systemctl set-default multi-user.target
  - Uninstall everything:     sudo ./cn60-waydroid-setup.sh --uninstall
EOM
}

# ------------------------------------------------------------ entry point
if [[ $MODE == uninstall ]]; then
    do_uninstall
else
    do_install
fi
