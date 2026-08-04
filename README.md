# waybar-airpods

waybar module showing per-bud and case AirPods battery, charging state and
in-ear detection.

BlueZ exposes no `Battery1` interface for AirPods. The only thing the standard
stack can offer is a single combined percentage over HFP, and only while the
headset profile is active, which is useless for a status bar. This reads the
real numbers instead by speaking Apple's AACP (Apple Accessory Communication
Protocol) over an L2CAP socket on PSM `0x1001`, the same channel a Mac uses.

Verified working on Void Linux, BlueZ 5.86, AirPods 3rd generation
(`bluetooth:v004Cp2013`, firmware 65.x).

## What you get

- Left, right and case battery, each with charging / discharging state
- In-ear detection
- A bar module that doubles as a connect toggle

The bar reads `pods L100% R100%`, gaining ` C80%` when the case reports.

**The case percentage is only available while a bud is sitting in the case.**
The case has no radio of its own, it reports through a bud, so with both buds
in your ears the AirPods send `case level=0 status=disconnected`. That is
filtered out rather than shown as a real `C0%`. Put a bud back in with the lid
open and the case figure appears.

Likewise a bud that is in the case reports as disconnected, so the bar shows
only the bud that is actually out.

## Layout

```
daemon/airpodsd            the daemon: holds the AACP link, writes state JSON
waybar/airpods-status.sh   waybar custom module, reads that JSON
install.sh                 symlinks the module into ~/.config/waybar
```

State is written to `$XDG_RUNTIME_DIR/airpodsd/state.json` and waybar is poked
with `SIGRTMIN+11` whenever it changes.

## Requirements

- Python 3 with PyGObject (`gi`), used for the BlueZ D-Bus queries. No
  `python-dbus`, no Qt, no extra pip packages.
- `jq` for the waybar module.
- The AirPods already paired with BlueZ.

## Install

```sh
./install.sh
```

Then add the module to `~/.config/waybar/config`:

```json
"custom/airpods": {
    "exec": "~/.config/waybar/airpods-status.sh",
    "return-type": "json",
    "interval": 30,
    "signal": 11,
    "tooltip": true
}
```

and put `"custom/airpods"` in `modules-right`. Start the daemon from your
compositor config, e.g. in `~/.config/sway/config`:

```
exec_always /mnt/shared/projects/waybar-airpods/daemon/airpodsd
```

## How it works

The daemon polls BlueZ over D-Bus for a connected device whose `Modalias`
starts with `bluetooth:v004C` (Apple) and whose UUIDs include the AACP service
`74ec2172-0bad-4d01-8f77-997b2be0722a`. It deliberately waits for BlueZ to
report the device as connected rather than attempting L2CAP on a timer, so it
never pages AirPods that are asleep in their case.

Once connected it opens L2CAP PSM `0x1001` and sends three packets:

```
handshake              00 00 04 00 01 00 02 00 00 00 00 00 00 00 00 00
host capabilities      04 00 04 00 4D 00 FF 00 00 00 00 00
notification register  04 00 04 00 0F 00 FF FF FF FF
```

After that the AirPods push notifications unprompted. The two this cares about:

```
battery    04 00 04 00 04 00 [count] ([component] 01 [level] [status] 01) * count
ear        04 00 04 00 06 00 [primary] [secondary]
```

Components are `02` right, `04` left, `08` case. Status is `00` unknown,
`01` charging, `02` discharging, `04` disconnected.

### Notes from the wire

Things worth knowing that the protocol docs do not spell out:

- Battery packets are **event driven**, not polled. One arrives shortly after
  the handshake, then only on change. A bar interval alone would show nothing,
  which is why the daemon signals waybar rather than the bar polling for state.
- A component that is not present reports `level 0` with status `disconnected`.
  The case does this constantly whenever its lid is shut. These entries are
  dropped, otherwise the bar shows a permanent "case 0%".
- Ear detection byte `0x03` is not in the published tables. It appears for a bud
  whose battery simultaneously reads `disconnected`, so it is treated as absent.
- The state file's timestamp cannot be used to detect a dead daemon, because a
  battery level that has not changed in an hour is still correct. The daemon
  writes its pid instead and the waybar module checks that it is alive.

## Prior art

[LibrePods](https://github.com/kavishdevar/librepods) did the reverse
engineering this builds on, and its `docs/` directory is the reference for the
packet formats. Its own Linux client is a Qt6 GUI application and is currently
mid-rewrite, which is more moving parts than a status bar readout needs.
