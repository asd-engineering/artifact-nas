# NAS-vendor helpers

Vendor-specific scripts and documentation for tuning a NAS appliance so it
plays nicely with the `artifact-nas` action under CI bursts. Sits beside
the action code because the action's runtime behaviour and the NAS's own
firewall/sshd settings are two halves of the same problem: an aggressive
`fail2ban`-equivalent on the appliance side will break SFTP uploads even
when the client side does everything right.

## Why this exists

`artifact-nas`'s `rclone_retry` wrapper (v1.2.0+) absorbs *transient* SFTP
init failures from sshd queue backpressure. It does **not** help when the
NAS has banned the runner's IP for hours/days (or permanently) after a
single failed auth — that ban outlives any reasonable retry budget. The
fix has to happen on the NAS:

- **whitelist** the runner IPs (or CIDR ranges) so they never get banned, or
- **loosen** the ban-policy thresholds so a hiccup doesn't trigger a long ban, or
- **disable** the auto-block feature entirely on isolated/trusted networks.

Vendor mechanisms differ wildly (Asustor `ipblock`, Synology `auto-block`,
QNAP `IP Access Protection`, TrueNAS `pf` rules, Unraid `iptables`). One
script-per-vendor under `nas/<vendor>/` keeps each clean.

## Layout

```
nas/
├── README.md                          ← this file
├── asustor/
│   ├── README.md                      ← ADM-side mechanics + file formats
│   └── whitelist-cicd.sh              ← fetch GitHub/GitLab IPs, format for defender.safe
├── synology/                          ← (contributions welcome)
├── qnap/                              ← (contributions welcome)
└── truenas/                           ← (contributions welcome)
```

## Status by vendor

| Vendor | Mechanism | Helper | Notes |
|---|---|---|---|
| **Asustor** | `/usr/builtin/etc/ipblock/` (ADM Defender) | `nas/asustor/whitelist-cicd.sh` | Confirmed working on AS6706T (ADM 4.x) |
| Synology | `auto-block` table in `synoinfodb.sqlite` | _wanted_ | Whitelist via DSM Control Panel → Security → Account → Auto Block |
| QNAP | `Network & Virtual Switch → Security → IP Access Protection` | _wanted_ | QTS exposes via web UI; CLI path TBD |
| TrueNAS Core | `pf` rules + `/etc/hosts.allow` | _wanted_ | More permissive defaults; mostly NA |
| TrueNAS Scale | `nftables` + Cluster API | _wanted_ | k3s-managed; helper might be a YAML |
| Unraid | `iptables` directly | _wanted_ | No built-in auto-ban; usually NA |

## Contribute

Drop a new directory `nas/<vendor>/` with at minimum:
- `README.md` — where the ban-policy lives, what format the whitelist takes, how to reload after a write
- `whitelist-cicd.sh` (or vendor-equivalent) — a script that idempotently adds CI IPs to the vendor's whitelist
