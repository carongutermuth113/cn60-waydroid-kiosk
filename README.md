# CN60 Waydroid Kiosk

Turn a CN60 mini PC (or any x86_64 box) running **Debian 13** into an
Android TV-style appliance: it boots straight into Android full screen, with
no Linux desktop.

Everything comes from one script, `cn60-waydroid-setup.sh`. Run it once to
install. Run it again later to add only what is new.

> **Status:** syntax-checked with `bash -n` and `shellcheck` only. It has not
> been run end to end on real CN60 hardware yet. Test it on a box you can
> reinstall, and open an issue with the output if something fails.

---

## What it does

| Area | What you get |
|---|---|
| **Android** | [Waydroid](https://waydro.id) with the VANILLA image (no Google apps), shown full screen at boot |
| **Kiosk** | No desktop environment. `cage` (a single-app Wayland compositor) runs Android on tty1 |
| **ARM apps** | libndk ARM translation through [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script), so ARM-only apps can run |
| **Display** | Resolution set from a config file: 1080p (default), 4K or 720p |
| **TV control** | Turns the TV on at boot and has on/standby buttons over HDMI-CEC |
| **Sound** | PipeWire (or PulseAudio, if already installed) for HDMI and Bluetooth audio |
| **Bluetooth** | Pair keyboards, mice, gamepads, remotes, headphones and speakers from a menu |
| **SSH** | OpenSSH server enabled. Root login over SSH is disabled |
| **Updates** | Daily security updates, plus a weekly full Debian + Android image upgrade |
| **OS tuning** | zram swap, journal size cap, no suspend, quiet fast boot, unneeded services off |
| **Settings menu** | `sudo cn60-settings`: text menu on Ctrl+Alt+F2 |
| **Safe re-runs** | Re-running applies only new or changed parts and keeps your settings |
| **Uninstall** | `--uninstall` reverts everything the script added or changed |

---

## Requirements

- x86_64 PC (built for the CN60 mini PC)
- Debian 13 "trixie", minimal install (no desktop needed)
- A normal user account with `sudo`
- A kernel with **binder** support (`binder_linux` module or binderfs). Debian's stock kernel has it
- Internet access. The first Waydroid download is about 1-2 GB
- A TV or monitor over HDMI. CEC is optional

---

## Quick start

On the CN60, logged in as your normal user:

```bash
# get the script
wget https://raw.githubusercontent.com/carongutermuth113/cn60-waydroid-kiosk/main/cn60-waydroid-setup.sh
# (private repo: copy it over with scp or a USB stick instead)

chmod +x cn60-waydroid-setup.sh
sudo ./cn60-waydroid-setup.sh
sudo reboot
```

After the reboot the box goes straight into Android.

If you copied the file from Windows and get `$'\r': command not found`, fix
the line endings first:

```bash
sed -i 's/\r$//' cn60-waydroid-setup.sh
```

---

## Script options

```text
sudo ./cn60-waydroid-setup.sh                    install; if already installed, add only what is new
sudo ./cn60-waydroid-setup.sh --no-upgrade       same, but skip the Debian/Android upgrade
sudo ./cn60-waydroid-setup.sh --force            redo every step, even ones already done
sudo ./cn60-waydroid-setup.sh --uninstall        remove everything this script added
sudo ./cn60-waydroid-setup.sh --uninstall --yes  same, without the confirmation prompt
./cn60-waydroid-setup.sh --help                  show usage
```

Run it with `sudo` from your **normal user**, not from a root login. Android
runs as that user. If you forget `sudo`, the script restarts itself with it.

---

## How it works

### Boot flow

```text
power on
  └─ GRUB (1 s, quiet boot)
      └─ systemd default target: graphical-kiosk.target
          ├─ multi-user.target        network, SSH, Bluetooth, user logins
          └─ waydroid-kiosk.service   on tty1
              └─ /usr/local/bin/cn60-kiosk-start      (root)
                  ├─ read /etc/cn60/display.conf → set Waydroid width/height
                  ├─ HDMI-CEC "power on" to the TV (best effort, 10 s max)
                  └─ cage (as your user)
                      └─ /usr/local/bin/cn60-kiosk-user
                          ├─ waydroid session start
                          └─ waydroid show-full-ui   ← Android full screen
```

- If the kiosk crashes, systemd restarts it (up to 3 times in 2 minutes).
- If it keeps failing, `cn60-fallback.service` brings back a text login on
  tty1 so the box is never dead.
- **Ctrl+Alt+F2** opens a text console at any time. **Ctrl+Alt+F1** goes back
  to Android.

### What the installer does, step by step

1. **Platform check.** Stops if the machine is not x86_64. Warns if it is not Debian 13.
2. **Packages.** Installs only the missing ones and records exactly which ones it added, so uninstall removes only those.
3. **Debian upgrade.** `apt full-upgrade`. Skip it with `--no-upgrade`.
4. **User groups.** Adds your user to `video`, `render`, `input` and `seat`/`_seatd`, and turns on *linger* so your user session exists at boot without a login.
5. **Binder.** Loads `binder_linux` or mounts binderfs, and sets it to load at boot. Stops with a clear error if the kernel has neither.
6. **Config.** Writes `/etc/cn60/user`, and `/etc/cn60/display.conf` (1920x1080) only if it does not exist yet.
7. **Waydroid.** Enables the container service and runs `waydroid init -s VANILLA` if no image exists yet.
8. **Helpers and units.** Writes the scripts in `/usr/local/bin` and the systemd units. A file is rewritten only when its content changed.
9. **One-time steps,** each tracked with a version number:
   - `arm-translation`: libndk through waydroid_script
   - `os-tuning`: see [OS tuning](#os-tuning)
   - `auto-updates`: unattended-upgrades plus the weekly timer
   - `ssh`: sshd hardening drop-in, service enabled
10. **Android image upgrade.** `waydroid upgrade`.
11. **Boot target.** Enables seatd, disables any desktop login manager, and sets `graphical-kiosk.target` as the default.
12. **Summary.** Prints what changed this run, the box's IP for SSH, and next steps.

### Re-running = updating

When `/etc/cn60/installed` exists, the script does not ask anything. It:

- installs only packages that are missing
- rewrites only helper files whose content changed
- skips one-time steps already done at the same version. Each step's version is stored in `/etc/cn60/steps/<name>`, and bumping the number in the script makes old installs run that step once more
- never overwrites your resolution in `display.conf`
- restarts the kiosk if it was running
- prints `Nothing new to add` when there is nothing to do

So to update a box, copy the newest script over the old one and run it again.

---

## Settings menu

Press **Ctrl+Alt+F2**, log in, then run:

```bash
sudo cn60-settings
```

| Option | What it does |
|---|---|
| `resolution` | 1080p (default), 4K (3840x2160) or 720p. Saves the choice and restarts Android |
| `bluetooth` | Scan/pair, status, reconnect, disconnect, forget devices |
| `tv` | TV on / standby over HDMI-CEC |
| `info` | IP address and SSH status |
| `restart` | Restart Android |
| `update` | Run a full Debian + Android update now |
| `reboot` | Reboot the box |

---

## Bluetooth

Bluetooth devices pair with **Debian**, not with Android. Waydroid cannot pass
Bluetooth through to Android apps. Once a device is connected to Debian:

- ✅ Keyboards, mice, gamepads and Bluetooth remotes work in Android as normal input
- ✅ Headphones and speakers play Android's sound
- ❌ Android apps that talk to Bluetooth gadgets directly (fitness bands, etc.) do not work

### Pairing from the menu

1. `sudo cn60-settings`, then **bluetooth**, then **pair**
2. Put the device in pairing mode (usually hold its pair/power button until a light flashes), then press OK
3. Wait for the 20-second scan and pick the device
4. The menu pairs, trusts and connects it. If a keyboard shows a code, type it on that keyboard and press Enter

Trusted devices reconnect by themselves after a reboot.

### Pairing by hand

```bash
sudo bluetoothctl
  power on
  scan on               # wait for your device's MAC address
  scan off
  pair AA:BB:CC:DD:EE:FF
  trust AA:BB:CC:DD:EE:FF
  connect AA:BB:CC:DD:EE:FF
  devices Connected
  exit
```

---

## SSH

SSH is enabled for normal users. Root login over SSH is turned off.

```bash
ssh <your-user>@<box-ip>
```

The installer prints the IP at the end, and the settings menu shows it under
`info`. Settings live in `/etc/ssh/sshd_config.d/90-cn60.conf`.

---

## Updates

| What | When | How |
|---|---|---|
| Debian security / stable updates | Daily | `unattended-upgrades`. Never reboots by itself |
| Full Debian upgrade + Waydroid Android image | Sundays 04:30 | `cn60-update.timer` runs `cn60-update --auto` |
| Same, by hand | Any time | `sudo cn60-update`, or **update** in the settings menu |
| Same, from the installer | Each run | Skip with `--no-upgrade` |

The weekly update stops Android, upgrades everything, and starts Android
again. It reboots **only** if a new kernel was installed.

```bash
systemctl list-timers cn60-update.timer          # next run
sudo systemctl disable --now cn60-update.timer   # turn weekly updates off
journalctl -u cn60-update -b                     # last update log
```

---

## OS tuning

All of these are undone by `--uninstall`.

| Tweak | Why |
|---|---|
| zram swap (zstd, 50% of RAM) | Compressed RAM swap; smoother on low-memory boxes |
| `vm.swappiness=10`, `vm.vfs_cache_pressure=50` | Keep apps in RAM longer |
| Journal capped at 200 MB | Disk never fills with logs |
| `DefaultTimeoutStopSec=15s` | Shutdown never hangs on a stuck service |
| Suspend / hibernate masked | A TV box should never go to sleep |
| `*-wait-online` masked | Boot does not wait for the network |
| ModemManager, CUPS disabled (if present) | Not needed on a TV box |
| `fstrim.timer` enabled | Weekly TRIM for SSD/eMMC |
| GRUB: 1 s timeout, `quiet loglevel=3 consoleblank=0` | Faster boot, screen never blanks |

Original files are backed up once under `/etc/cn60/backup/` before the first
edit. Units the script masks, disables or enables are recorded under
`/etc/cn60/` so uninstall reverses exactly those.

---

## Files on the box

| Path | Purpose |
|---|---|
| `/etc/cn60/display.conf` | Resolution (`WIDTH=`, `HEIGHT=`) |
| `/etc/cn60/user` | Kiosk user |
| `/etc/cn60/version`, `installed`, `steps/` | Install state for safe re-runs |
| `/etc/cn60/packages-added`, `groups-added`, `masked`, `disabled`, `enabled`, `backup/` | What uninstall will revert |
| `/usr/local/bin/cn60-settings` | Settings menu |
| `/usr/local/bin/cn60-update` | Updater |
| `/usr/local/bin/cn60-kiosk-start`, `cn60-kiosk-user` | Kiosk launchers |
| `/etc/systemd/system/waydroid-kiosk.service` | The kiosk |
| `/etc/systemd/system/cn60-fallback.service` | Text login if the kiosk fails |
| `/etc/systemd/system/graphical-kiosk.target` | Default boot target |
| `/etc/systemd/system/cn60-update.{service,timer}` | Weekly update |

---

## Useful commands

```bash
# kiosk
sudo systemctl start|stop|restart waydroid-kiosk
systemctl status waydroid-kiosk
journalctl -u waydroid-kiosk -b -f

# Waydroid
waydroid status
waydroid app list
waydroid app install /path/to/app.apk
waydroid prop get persist.waydroid.width
sudo waydroid shell
sudo waydroid log

# resolution without the menu
sudo nano /etc/cn60/display.conf && sudo systemctl restart waydroid-kiosk

# TV by hand
echo 'on 0'      | cec-client -s -d 1
echo 'standby 0' | cec-client -s -d 1

# boot mode
sudo systemctl set-default multi-user.target       # normal text boot
sudo systemctl set-default graphical-kiosk.target  # back to the kiosk
```

---

## Troubleshooting

**`Permission denied` / `sudo: ./cn60-waydroid-setup.sh: command not found`**
The file lost its executable bit while being copied. Run `chmod +x cn60-waydroid-setup.sh`, or start it with `sudo bash ./cn60-waydroid-setup.sh`.

**`$'\r': command not found` or `bash\r: No such file or directory`**
The file has Windows line endings. Fix them with `sed -i 's/\r$//' cn60-waydroid-setup.sh`.

**SSH: "System is booting up. Unprivileged users are not permitted to log in yet"**
Fixed in script version 4. Older versions booted without
`systemd-user-sessions`, which left `/run/nologin` in place. To recover:
- if you have a root password: on the box, Ctrl+Alt+F2, log in as root, run `systemctl start systemd-user-sessions`
- otherwise: reboot, tap **Esc** for the GRUB menu, press **e**, add
  `systemd.unit=multi-user.target` to the end of the `linux` line, and press **Ctrl+X**

Then run the latest script and reboot.

**"No binder support in this kernel"**
Your kernel lacks `CONFIG_ANDROID_BINDER_IPC`. Use Debian's stock kernel.

**No sound**
Check `systemctl --user -M <user>@ status pipewire-pulse`. For Bluetooth audio, check the device is connected (`bluetoothctl devices Connected`), then **restart** from the menu.

**Black screen / kiosk keeps restarting**
Check `journalctl -u waydroid-kiosk -b` and `sudo waydroid log`. After 3
failures you get a text login on tty1 automatically.

---

## Uninstall

```bash
sudo ./cn60-waydroid-setup.sh --uninstall
sudo reboot
```

This removes the kiosk, Waydroid and **all Android data**, the ARM
translation, the helper scripts and units, the OS tweaks (original files are
restored), the auto-updates, the group memberships it added, and only the
packages it installed. If the script installed SSH, SSH is removed too, so
run the uninstall at the box, not over SSH.

---

## Credits

- [Waydroid](https://waydro.id)
- [cage](https://github.com/cage-kiosk/cage)
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) for the libndk ARM translation (third-party; check its license)

## License

MIT, see [LICENSE](LICENSE).
