# Asustor NAS CI SFTP — geo-block root cause & reliability runbook

**Version:** 1.0.0 | **Last Updated:** 2026-06-03 | **Status:** ACTIVE

> The story of why CI artifact uploads to the Asustor NAS kept failing for
> weeks, what the *actual* root cause was (not the ones we first chased), and
> the durable fix. Read alongside [`ASUSTOR_PLATFORM_NOTES.md`](./ASUSTOR_PLATFORM_NOTES.md)
> and [`README.md`](./README.md). Apply with [`fix-sftp-cicd.sh`](./fix-sftp-cicd.sh).

## TL;DR

CI uploads (`couldn't initialise SFTP: handshake failed: EOF`) had **two**
independent root causes, both on the NAS itself — not the router, not
concurrency, not rclone:

1. **ADM Defender GEO-BLOCK** (the big one) — the NAS firewall drops inbound by
   *source-IP geography*. GitHub Actions runners are US-registered Azure, so
   they were dropped **before reaching `sshd_sftp`**. EU-registered runners and
   LAN passed, which is exactly why it was so hard to see.
2. **MaxStartups throttle-WEDGE** — `sshd_sftp` can get stuck in permanent
   MaxStartups throttling while still *listening*, dropping every connection.
   The old watchdog only checked "is the port up?", so it never caught this
   (once wedged 6h22m / 6484 connections dropped).

Both are fixed NAS-side and proven by an external load test (see Results).

---

## 1. The geo-block (the real CI root cause)

### Mechanism
ADM Defender (`defenderd`) compiles its rules to nftables in
`/usr/builtin/etc/defender/firewall.nft_*`. In chain
`ip Asustor_Firewall_V4 Filter` (top-down):

```
ct state established,related accept
jump TrustedIP                       # only ~6 source IPs (incl the NAS's own WAN)
ip saddr @AbuseIP4 drop
ip saddr @SA_* drop                  # South America
ip saddr @NA_US.ipv4_0..10 drop      # NORTH AMERICA / US  (103 NA ipsets!)
ip saddr @AS_* / @AF_* / @OC_* / @AN_* drop
```

Source: the active profile `Migration_ADM Defender`
(`/usr/builtin/etc/defender/profiles.json`) denies continents
`SA/OC/NA/AN/AF/AS`. **Only Europe + the TrustedIP list is allowed inbound.**
GitHub runners (US Azure) land in `@NA_US` → dropped at the firewall, never
reaching `sshd_sftp`.

### Why it hid for weeks
- **LAN tests were always clean** — `192.168.x` isn't in any geo set.
- **The occasional pass** — a runner whose IP is EU-*registered* (e.g. a
  KPN/RIPE range Azure happens to host in the US) is seen as EU and allowed,
  so single-connection probes intermittently succeeded.
- **`absent from the SFTP log`** — packets dropped by nftables never reach
  `sshd_sftp`, so the failures don't appear in any SFTP/auth log (and
  `sshd_sftp` doesn't log to `/var/log/messages` anyway). This made it look
  like a network/router problem.
- **GitHub fallback masked it** — the `artifact-nas` action uploads to GitHub
  artifacts when the NAS fails, so `[ci all]` went green while the NAS path was
  silently dead. The hourly `nas-health` probe only catches it when its runner
  happens to be US-registered.

### Diagnosis instrument
The external, geo-tagged load test in
`git@github.com:asd-engineering/nas-test.git` (workflow `nas-loadtest.yml`) fans
real `rclone copyto` uploads across N GitHub runners — each tagged with its
egress IP + continent. It has **no GitHub fallback**, so it shows the true
NAS-only signal. A batch of all-NA runners under the geo-block = 0 uploads;
with the bypass = all upload + byte-verify.

### The fix — keep the firewall ON, exempt only the CI port
ADM Defender's rules are **source-based only** (no port scoping in this
profile schema), so "allow only :4589" is not expressible in the UI. We insert
it directly into nftables, ahead of the geo-drops:

```sh
/usr/builtin/sbin/nft insert rule ip Asustor_Firewall_V4 Filter \
    tcp dport 4589 ct state new accept
```

Safe because SFTP/4589 has key/password auth + ipblock + the hardened sshd, so
geo-blocking *that one port* is redundant — **the geo-block stays fully intact
for every other service.** `fix-sftp-cicd.sh` applies this and the per-minute
watchdog re-asserts it (defenderd flushes its Filter chain on every reload).

**Caveat:** for ~60 s after any ADM Defender config change (defenderd
regenerates + flushes the rule) the bypass is gone until the watchdog re-adds it
on its next tick — covered by rclone's ~120 s retry budget. A probe that runs in
that window shows a transient "down".

### Alternatives (if you don't want the watchdog dependency)
- **Docker SFTP container** on host port 4589 — Docker-published ports bypass
  ADM Defender natively (PREROUTING/FORWARD, not the host Filter chain), so the
  geo-block never touches it and there's **zero gap**. Keeps geo on everything
  else. Most robust; one-time migration of the asd-cicd user/keys/volume.
- **Allow North America** in ADM Defender — one UI edit (delete/flip the `NA_`
  deny rule). Native + persistent, but opens *all* of NA to your NAS services
  (still behind their own auth + ipblock).

---

## 2. The MaxStartups throttle-wedge (the second root cause)

`sshd_sftp` can leak/stick its pre-auth startup counter above the MaxStartups
threshold and enter **permanent throttling while still listening** — it then
drops every new connection with EOF. Observed 2026-06-03: wedged **6h22m**,
**6484 connections dropped**, hourly probe red the whole time. The old watchdog
checked only "is port 4589 listening?" → saw "yes" → never restarted it.

### Fix — watchdog does a real handshake probe
`fix-sftp-cicd.sh` installs a watchdog that reads the **SSH banner** via `nc`:
a healthy `sshd_sftp` sends `SSH-2.0-…` on TCP accept; a down *or* throttle-
wedged one closes without a banner. Two strikes 2 s apart (avoid flapping) →
restart, which clears the stuck counter. It also writes
`/tmp/sftp-watchdog.heartbeat` each run so you can confirm cron is firing.

**Manual recovery:** `sudo /usr/builtin/etc/init.d/S79sftpmand stop; sleep 2;
sudo /usr/builtin/etc/init.d/S79sftpmand start`.

---

## 3. Upload destination gotcha

`asd-cicd` home is `/home/asd-cicd`; there is **no chroot**, so rclone roots at
the user's home. The real artifact dir is **`ci-artifacts`** (org secret
`NAS_DEST`) → `/home/asd-cicd/ci-artifacts`. **`/artifacts` does not exist** —
`nas-doctor.sh`'s default `NAS_DEST=/artifacts` will falsely report
`round-trip DEGRADED` (it's a path error, not a daemon problem). Always export
the real `NAS_DEST`.

---

## 4. Verification & monitoring

```sh
# watchdog alive? (timestamp within ~120 s = cron firing, both protections live)
ssh nas-kelvin 'now=$(date +%s); echo $(( now - $(cat /tmp/sftp-watchdog.heartbeat) ))s'

# daemon serving (not wedged)? — 'Permission denied' = KEX completing
ssh -p 4589 -o PreferredAuthentications=none asd-cicd@<nas> exit   # expect "Permission denied"

# geo-bypass present? (needs root)
sudo /usr/builtin/sbin/nft list chain ip Asustor_Firewall_V4 Filter | grep 'dport 4589'

# external re-test after any change: dispatch nas-test fanout=20 (firewall ON)
```

---

## 5. Load-test results (firewall ON, production config)

External `nas-test` load test (real `rclone copyto` uploads from US-registered
GitHub runners, **firewall ON**, every file byte-verified, no GitHub fallback):

| fan-out | raw no-retry client | **optimized client** (`nas-rclone.sh` / artifact-nas) | daemon after |
|---|---|---|---|
| 20 | 0% fail (×2 runs, consistent) | — | `0 of 200`, no throttle |
| 40 | **38% fail**, 0/40 verified | **0% fail, 40/40 verified** | `0 of 200`, no throttle |
| 80 | **43% fail**, 20/80 verified | **0% fail, 79/80 verified** | `0 of 200`, no throttle |

**Conclusions:**
- The hardened daemon **never wedged** — even at 80 concurrent US runners with the
  aggressive raw client, startups returned to `0` with no throttling. (Realistic
  `[ci all]` peak is ~8–12 concurrent, so this is 4–8× headroom.)
- The raw client's 38–43% failures at high fan-out are transient MaxStartups
  back-pressure; the **optimized client recovers all of them** (broad transient-
  retry + jittered backoff + paced/capped connections) → **0% fail at 40 *and*
  80 concurrent.** Lower raw throughput is the deliberate trade for reliability.
- Re-run anytime: dispatch `nas-test` `nas-loadtest.yml` at fanout 20/40/80.

---

## Apply order (full NAS-side fix)

1. `sudo python3 patch-sshd-session.py`  (DefaultAllowGroups → users)
2. `sudo python3 patch-seccomp.py`       (seccomp unlink KILL → ALLOW)
3. `sudo sh fix-sftp-cicd.sh`            (MaxStartups/LoginGraceTime/sysctls/ipblock
   + geo-bypass nft rule + banner-probe watchdog + restart)
4. Keep ADM Defender firewall **ON**; verify with `nas-test` fanout=20.

Re-run step 3 after any firmware update (restores patched binary + config) and
after toggling the firewall (re-asserts the geo-bypass immediately).
