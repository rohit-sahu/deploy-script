# Firewall, Docker & iptables — A Beginner's Guide (and Reference)

This doc explains, from first principles, how traffic actually reaches this
app on an EC2 instance, why a "correctly configured" host firewall can still
let direct-IP traffic through when Docker is involved, and how this repo's
scripts (`prod-bootstrap.sh`, `verify-bootstrap.sh`) solve that. Written so a
future you (or anyone else) can re-derive the reasoning without re-debugging
it from scratch.

If you just want the fix, jump to [The Docker + ufw
problem](#the-docker--ufw-problem-the-one-beginners-almost-always-hit) and
[The fix](#the-fix-the-docker-user-chain).

---

## 1. The four layers of defense (and why we need all of them)

A request to `https://rohit.techsky.in` (or your domain) can be blocked at
**four different layers**, from outermost to innermost. Understanding which
layer does what is the key to debugging "why can I still access this
directly" problems.

```
Internet
   │
   ▼
┌─────────────────────────────────────────────┐
│ 1. Cloudflare (proxy/orange-cloud)           │  ← DNS-level: hides your real IP,
│    - Only relevant if proxy is ON             │     but does NOT block direct-IP
│    - Terminates TLS, proxies to your origin   │     access if someone already knows it
└─────────────────────────────────────────────┘
   │ (traffic that reaches your EC2's public IP directly, bypassing Cloudflare)
   ▼
┌─────────────────────────────────────────────┐
│ 2. AWS Security Group (SG)                   │  ← VPC/hypervisor level, OUTSIDE
│    - Filters BEFORE packets reach your OS     │     your instance's own OS/kernel.
│    - Cannot be bypassed by anything running    │     Docker running on the instance
│      inside the instance (Docker included)    │     can NEVER see traffic the SG
└─────────────────────────────────────────────┘        already dropped.
   │ (traffic the SG allowed through)
   ▼
┌─────────────────────────────────────────────┐
│ 3. Host firewall (ufw / iptables INPUT chain)│  ← Runs inside your EC2 instance's
│    - Only exists on Ubuntu/Debian in this      │     own Linux kernel.
│      repo's setup (Amazon Linux skips it,     │
│      relies on the SG alone)                  │
└─────────────────────────────────────────────┘
   │ (traffic for a port a container publishes, e.g. 80/443)
   ▼
┌─────────────────────────────────────────────┐
│ 4. Docker's own iptables rules (FORWARD      │  ← THIS is the layer that silently
│    chain / DOCKER-USER chain)                 │     bypasses layer 3 if you don't
│    - Docker manages published container ports │     know about it. See below.
│      with its OWN iptables rules              │
└─────────────────────────────────────────────┘
   │
   ▼
Your container (e.g. nginx listening on :80)
```

**Key takeaway:** these layers are independent. Fixing layer 3 (ufw) does
nothing for layer 4 (Docker's rules) — they're evaluated at different points
in the kernel's packet-filtering pipeline. This repo's `CLOUDFLARE_ONLY_WEB`
hardening needs to correctly configure **layers 2, 3, and 4** together to
actually restrict direct-IP access (layer 1, Cloudflare, is a proxy/DNS
concern, not a firewall — see [ADMIN_SECURITY.md](./ADMIN_SECURITY.md) and
[PRODUCTION_DEPLOYMENT.md](./PRODUCTION_DEPLOYMENT.md) Step 9 for how
Cloudflare proxy mode fits in).

---

## 2. What is a firewall, and what is `ufw`?

A **firewall** is just a set of rules that decide whether to let a network
packet through or drop it, usually based on source IP, destination port,
and protocol.

On Linux, the actual packet filtering is done by the kernel's **netfilter**
subsystem, which you configure via **`iptables`** (or the newer `nftables`).
Raw `iptables` syntax is verbose and easy to get wrong, so Ubuntu/Debian ship
**`ufw`** ("Uncomplicated Firewall") — a friendly wrapper that generates
`iptables` rules for you.

```bash
sudo ufw allow 22/tcp          # generates iptables rules allowing port 22
sudo ufw status verbose        # shows the human-readable summary
sudo iptables -L INPUT -n      # shows the ACTUAL raw rules ufw created
```

**Important:** `ufw`'s rules live in the kernel's `INPUT` chain (for traffic
destined for the host itself) and a few related chains. This matters because
Docker's published-port traffic does **not** go through `INPUT` — see below.

Amazon Linux (this repo's other supported OS) doesn't use `ufw` at all —
`prod-bootstrap.sh`'s hardening skips the host firewall entirely there and
relies solely on the AWS Security Group (layer 2) as the perimeter. That's
intentional: on Amazon Linux, there's no host-firewall-vs-Docker problem to
begin with, because there's no host firewall in the mix.

---

## 3. How Docker actually publishes a port

When your `docker-compose.yml` has:

```yaml
services:
  nginx:
    ports:
      - "80:80"
      - "443:443"
```

Docker does **not** just "open a port" the way a plain process listening on
`0.0.0.0:80` would. Instead, on container start, the Docker daemon (`dockerd`)
inserts its own `iptables` rules to:

1. **DNAT** (Destination NAT) incoming traffic on the host's `80` to the
   container's internal IP on the `docker0`/bridge network, port `80`.
2. **Accept** that forwarded traffic in the kernel's `FORWARD` chain (since
   the packet's destination is now the container, not the host itself —
   forwarded traffic is filtered by `FORWARD`, not `INPUT`).

This is why `docker ps` shows `0.0.0.0:80->80/tcp` — that arrow is exactly
this DNAT+forward mechanism.

**The critical detail:** ufw's rules are almost entirely in the `INPUT`
chain. Docker's forwarding rules are in the `FORWARD` chain. **They are two
separate rule sets, evaluated for different kinds of traffic.** A packet
destined for a Docker-published port is forwarded traffic, so `INPUT` (and
therefore ufw) is never consulted for it at all.

---

## 4. The Docker + ufw problem (the one beginners almost always hit)

Given the above, you'd reasonably expect: "well then ufw is just useless for
Docker ports, right?" — not quite. Docker actually anticipated this and
created a special chain just for admins:

```bash
sudo iptables -L FORWARD -n --line-numbers
# Chain FORWARD (policy DROP)
# num  target          ...
# 1    DOCKER-USER     ...   ← consulted FIRST
# 2    DOCKER-FORWARD  ...   ← Docker's own port-publishing ACCEPT rules
# 3    ufw-before-forward ...
# ...
```

`DOCKER-USER` is a chain Docker creates (empty, by default) specifically so
admins can add custom filtering for forwarded/published-port traffic — and
it is checked **before** `DOCKER-FORWARD` (Docker's own rules that accept
published-port traffic). This means:

- If `DOCKER-USER` is **empty** (the default): every packet falls through it
  untouched, reaches `DOCKER-FORWARD`, which happily accepts it — your
  container is reachable from anywhere, **regardless of what ufw says.**
- If you add a `DROP`/`RETURN` policy to `DOCKER-USER` yourself, your rules
  win, because this chain is consulted first.

**This is exactly the bug we hit in this project:** `ufw status` correctly
showed Cloudflare-only rules on `80,443/tcp`, but `sudo iptables -L
DOCKER-USER -n` was completely empty — so direct-IP HTTPS requests to the
nginx container (published via `docker-compose`) sailed straight through,
ufw's correct-looking rules notwithstanding.

### How to check for this yourself

```bash
sudo iptables -L DOCKER-USER -n --line-numbers
```

- If this is **empty** and you're relying on ufw to restrict Docker
  published ports (80/443) — you are **not actually restricted**, no matter
  what `ufw status` shows.
- If it has rules ending in a comment like `/* cf-fw-managed */` — that's
  this repo's fix (see below) doing its job.

---

## 5. The fix: the `DOCKER-USER` chain

`prod-bootstrap.sh`'s `module_docker_user_firewall()` (Ubuntu/Debian only —
gated because Amazon Linux has no host firewall to bypass in the first
place) adds exactly this: rules directly in `DOCKER-USER` that:

1. Allow established/related connections through (so nothing already
   connected gets cut).
2. `RETURN` (allow) traffic on ports 80/443 from each of Cloudflare's
   published IP ranges.
3. `DROP` everything else on ports 80/443.
4. `RETURN` (allow) everything else — i.e. this only ever restricts ports
   80/443, leaving all other forwarded traffic (container-to-container,
   other published ports, etc.) untouched.

```bash
# Simplified version of what gets installed —
# see /usr/local/bin/docker-user-cloudflare-fw.sh on the server for the real,
# self-updating version.
iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -I DOCKER-USER -p tcp -m multiport --dports 80,443 -s <cloudflare-cidr> -j RETURN   # repeated per CIDR
iptables -A DOCKER-USER -p tcp -m multiport --dports 80,443 -j DROP
iptables -A DOCKER-USER -j RETURN
```

All rules are tagged with an iptables comment (`cf-fw-managed`) so the script
can safely rebuild just its own rules on every run without touching any other
custom `DOCKER-USER` rules you might add later.

### Why this needs to survive reboots (and how it does)

Docker **recreates an empty `DOCKER-USER` chain** every time `docker.service`
(re)starts — including on every instance reboot. Rules added directly via
`iptables` are **not persistent** on their own. To handle this,
`prod-bootstrap.sh` also installs a systemd unit:

```
/etc/systemd/system/docker-user-cloudflare-fw.service
  After=docker.service
  Requires=docker.service
  ExecStart=/usr/local/bin/docker-user-cloudflare-fw.sh
```

This re-applies the rules automatically every time `docker.service` starts
(i.e. on every boot). The weekly Cloudflare-IP-refresh cron
(`/etc/cron.d/cloudflare-fw-refresh`) also re-invokes this same script, so
both IP-range updates *and* self-healing (if something else wiped the chain
mid-week) happen automatically.

---

## 6. AWS Security Groups vs. host firewall — what's the actual difference?

This trips people up because both "look like" firewalls, but they operate at
completely different levels:

| | AWS Security Group (SG) | Host firewall (ufw / iptables) |
|---|---|---|
| **Where it runs** | AWS's hypervisor/network layer, *outside* your instance | Inside your instance's own Linux kernel |
| **Can Docker bypass it?** | **No** — Docker's iptables rules run inside the guest OS; they never even see traffic the SG already dropped | **Yes** — Docker's `DOCKER-FORWARD` rules run in the same kernel as ufw's rules, so ordering/chains matter (see above) |
| **Survives instance compromise?** | Yes — even if someone gets root on your instance, they can't change the SG without AWS API credentials | No — root on the instance can trivially flush/change any host firewall rule |
| **Granularity** | Coarse (protocol/port/CIDR) | Fine (anything `iptables` can express) |

**Practical implication:** the Security Group is your *strongest* and
*simplest* layer — if you only do one thing, lock down the SG. The host
firewall (and the `DOCKER-USER` fix above) is defense-in-depth for
Ubuntu/Debian, valuable in case the SG is ever accidentally loosened, but it
is not a substitute for the SG.

This is why `module_cloudflare_security_group()` in `prod-bootstrap.sh`
manages the SG (via the `aws` CLI, requires `AWS_SECURITY_GROUP_ID` + an IAM
role/credentials) **independently** of the ufw/`DOCKER-USER` work — both are
applied when `CLOUDFLARE_ONLY_WEB=true`.

---

## 7. How this repo layers all of it together

With `CLOUDFLARE_ONLY_WEB=true` and Cloudflare proxy (orange-cloud) enabled,
a legitimate visitor's request flows like this:

```
Visitor → Cloudflare edge (TLS terminated/proxied)
        → Cloudflare's own IP hits your EC2 public IP on 443
        → AWS Security Group: allowed (source IP is in Cloudflare's published ranges)
        → ufw (host firewall): allowed (same CIDR match)
        → DOCKER-USER chain: RETURN (same CIDR match) → falls through to DOCKER-FORWARD → accepted
        → nginx container receives the request
```

An attacker hitting your EC2's public IP directly (bypassing Cloudflare):

```
Attacker → EC2 public IP on 443 directly
         → AWS Security Group: DROPPED (source IP not in Cloudflare's ranges) — request never even reaches the OS
```

...or, if the SG were somehow misconfigured/open (defense-in-depth kicking in):

```
Attacker → EC2 public IP on 443 directly
         → AWS Security Group: allowed (hypothetically open)
         → ufw: DROPPED (source IP not in Cloudflare's ranges, INPUT-chain rule) — for host-level traffic
         → DOCKER-USER chain: DROP (source IP not in Cloudflare's ranges, for Docker-published ports) — this is the fix
```

Both the SG and the `DOCKER-USER` chain need to actively drop the traffic for
Docker-published ports; ufw's `INPUT` rules alone are not sufficient for
those ports, per section 4 above.

---

## 8. Cheat sheet — commands you'll actually use

```bash
# --- ufw (host firewall, Ubuntu/Debian) ---
sudo ufw status verbose                      # human-readable summary
sudo ufw --force reset                       # wipe ALL rules (careful — re-add SSH before enabling!)

# --- Docker's published-port bypass (the DOCKER-USER chain) ---
sudo iptables -L DOCKER-USER -n --line-numbers   # see what's actually restricting Docker ports
sudo iptables -L FORWARD -n --line-numbers       # see chain evaluation order (DOCKER-USER should be rule #1)
sudo systemctl status docker-user-cloudflare-fw.service   # is our fix's boot-time unit enabled/ran OK?
sudo /usr/local/bin/docker-user-cloudflare-fw.sh           # manually re-apply the rules right now

# --- AWS Security Group ---
aws ec2 describe-security-groups --group-ids sg-xxxxxxxx   # see current inbound rules
# (needs an IAM role attached to the instance, or `aws configure` credentials)

# --- Weekly refresh (keeps Cloudflare IP ranges current across all 3 layers) ---
cat /etc/cron.d/cloudflare-fw-refresh
cat /var/log/cloudflare-fw-refresh.log

# --- The all-in-one verifier ---
sudo CLOUDFLARE_ONLY_WEB=true AWS_SECURITY_GROUP_ID=sg-xxxxxxxx bash verify-bootstrap.sh
```

---

## 9. Troubleshooting checklist: "I locked things down but can still access the site directly"

Work through these **in order** — each layer can independently let traffic
through even if the others are correctly configured:

1. **Is DNS actually pointing at this instance?**
   `dig +short yourdomain.com` — confirm it matches this instance's public IP.
2. **Are you testing with a fresh connection, not a cached one?**
   Browsers reuse existing TCP/TLS connections; firewall changes only affect
   *new* connections. Test with `curl -v --connect-timeout 8
   https://yourdomain.com` from a network that's definitely not Cloudflare
   (e.g. your phone on mobile data), or from a completely different machine.
3. **Is the AWS Security Group actually locked down?**
   Check the AWS Console → EC2 → your instance → Security tab → look at
   *every* attached SG (there can be more than one!) for any `0.0.0.0/0` or
   `::/0` rule on 80/443.
4. **Is ufw actually active and correctly configured?**
   `sudo ufw status verbose` — should show `Status: active` and per-CIDR
   Cloudflare rules on `80,443/tcp`, not `Anywhere`.
5. **Is the `DOCKER-USER` chain actually populated?** *(the one everyone
   misses — see section 4)*
   `sudo iptables -L DOCKER-USER -n` — if empty, Docker's own rules are
   letting everything through regardless of what ufw says.
6. **Run the verifier script** for a full automated check of all of the
   above: `sudo CLOUDFLARE_ONLY_WEB=true AWS_SECURITY_GROUP_ID=sg-xxxxxxxx
   bash verify-bootstrap.sh`.

---

## 10. Key gotchas / things beginners get wrong

- **"ufw shows the right rules, so I'm protected."** Not necessarily — see
  section 4. Always check `DOCKER-USER` too if you run Docker.
- **"I tested in my browser and it still works, so the firewall failed."**
  Might just be a reused connection or DNS/browser cache — always retest
  with `curl` from a fresh connection/different network (section 9, step 2).
- **"Amazon Linux needs the same ufw fix."** No — Amazon Linux has no ufw at
  all in this repo's setup; it relies entirely on the Security Group, which
  Docker can never bypass (it's outside the guest kernel). The
  `DOCKER-USER` fix only applies to Ubuntu/Debian.
- **"`ufw --force reset` is safe to run anytime."** It wipes *all* rules,
  including any you or someone else added manually outside this script's
  control — re-run and review before relying on it in a live environment.
- **"DOCKER-USER rules will survive a reboot once I add them."** They won't,
  by themselves — Docker recreates an empty chain on every `docker.service`
  start. You need the systemd unit (or equivalent re-apply-on-boot
  mechanism) described in section 5.
- **"Restricting to Cloudflare's IPs blocks Let's Encrypt renewal."** Not if
  Cloudflare proxy (orange-cloud) is ON — the ACME validator's traffic
  arrives *via* Cloudflare's IPs, which are allowlisted. See
  `PRODUCTION_DEPLOYMENT.md` Step 8/9 for the full renewal explanation.

---

## Related files in this repo

- [`scripts/prod-bootstrap.sh`](./scripts/prod-bootstrap.sh) — implements all
  of layers 2/3/4 (`module_cloudflare_security_group`, `module_firewall`,
  `module_docker_user_firewall`).
- [`scripts/verify-bootstrap.sh`](./scripts/verify-bootstrap.sh) — automated
  checks for all of the above (Sections 2 and 3).
- [`PRODUCTION_DEPLOYMENT.md`](./PRODUCTION_DEPLOYMENT.md) — Step 9 covers
  the beginner walkthrough for enabling `CLOUDFLARE_ONLY_WEB` end-to-end,
  including the Cloudflare SSL-mode chicken-and-egg issue on first cert
  issuance.
- [`ADMIN_SECURITY.md`](./ADMIN_SECURITY.md) — the *application-level*
  (nginx/`CLOUDFLARE_PROXIED`) Cloudflare IP-trust setup — a related but
  distinct concern from the *network-level* firewall work described here.
