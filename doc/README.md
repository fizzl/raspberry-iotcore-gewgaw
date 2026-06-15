# gewgaw documentation

Per-feature technical docs for the gewgaw Raspberry Pi 3 sensor image. Start with
the top-level [`../README.md`](../README.md) for the end-to-end "build → flash →
provision → upload" walkthrough; come here for how each piece actually works.

| Doc | Covers |
| --- | --- |
| [build-system.md](build-system.md) | The Yocto harness: `setup.sh`, `build.sh`, `flash.sh`, `boot.sh`, the managed `local.conf` block, layer registration, image contents, partition layout, first-boot rootfs growth. |
| [networking.md](networking.md) | The wired management plane: static `eth0`, SSH key flow, sshd policy. |
| [wifi.md](wifi.md) | The two mutually-exclusive `wlan0` modes (dev vs. opportunistic), `setup-wlan.sh`, `add-network.sh`, `networks.conf`, the regdomain caveat. |
| [aws-iot.md](aws-iot.md) | AWS IoT Core integration: the `aws-iot-mqtt` helper, the cert/secret flow, `provision-device.sh`, topics, the IoT policy, and the manual AWS-side setup. |
| [collector.md](collector.md) | `gewgaw-collector`: Wi-Fi + BLE scanning, the SQLite presence model, and the single-radio arbiter. |
| [submit.md](submit.md) | `gewgaw-submit`: opportunistic upload, candidate selection, the `net_health` blacklist, the boot beacon, the `events` queue, and upload format. |

## Conventions used across the device

- **Config files** are shell-style `KEY=VALUE`, sourced or parsed by the daemons:
  `/etc/aws-iot/aws-iot.conf`, `/etc/gewgaw/gewgaw.conf`.
- **Runtime-only secrets** (device cert/key, Wi-Fi PSKs) are never baked into the
  image or committed — they are pushed to the running target over SSH and must be
  re-applied after every reflash.
- **No `sqlite3` CLI on the device** — only the Python `sqlite3` module ships. To
  inspect the DB, either pull `/var/lib/gewgaw/gewgaw.db` off the device with
  `scp` and open it on the host, or pipe a script in:
  `ssh … 'python3 -' < query.py`.
- The Pi 3 has **one 2.4 GHz radio** and **no RTC** — two constraints that shape
  most of the collector/submit behavior (see [collector.md](collector.md) and
  [submit.md](submit.md)).
</content>
</invoke>
