# Script Input Reference — Production Stack (`deploy 2.sh`, `publish-ghcr 2.sh`)

A beginner's guide to how `deploy 2.sh` and `publish-ghcr 2.sh` get their settings (like your domain, image tag, or the container's internal working directory). These are the **full production stack** variants (nginx + Caddy for automatic HTTPS + the app, optionally a Cloudflare Tunnel) — see [SCRIPT_INPUTS.md](./SCRIPT_INPUTS.md) for the simpler app-only `deploy.sh`/`scripts/publish-ghcr.sh` pair instead.

Every setting on both scripts can come from **four or five different places**, tried in a fixed order until one has a value. This doc explains what those places are, and lists every setting each script accepts.

If you've never used a script like this before, read [How input resolution works](#how-input-resolution-works) first — it explains the concept once, in plain terms, before the per-script reference tables.

---

## How input resolution works

Think of each setting (e.g. "which domain to deploy to") as a question the script needs answered before it can run. Instead of always asking you interactively, it checks **five sources**, in this exact order, and uses the **first one that has an answer**:

1. **CLI flag / positional arg** — something you typed on the command line when running the script, e.g.:
   ```bash
   ./deploy\ 2.sh your-domain.com --app-dir /app
   ```
   This always wins if present — it's the most explicit thing you could have done.

2. **Raw already-exported environment variable** — a value already sitting in your shell environment, checked *before* either file, e.g.:
   ```bash
   export DOMAIN=your-domain.com
   # -- or, prefix form, same effect for a single run --
   DOMAIN=your-domain.com ./deploy\ 2.sh
   ```
   `publish-ghcr 2.sh` doesn't have its own persisted state (step 3 below), so for it this is effectively "environment variable or fallback file" as one combined step — but for `deploy 2.sh`, this is checked and can win *before* its own remembered `.env` state, which is useful for a one-off override without disturbing what gets saved for next time.

3. **`deploy 2.sh` only — this script's own state file (`.env`)** — automatically writes every resolved setting (`DOMAIN`, `NEXT_PUBLIC_SITE_URL`, `CADDYFILE`, `APP_DIR`, `IMAGE`) to `.env` after every successful run. A bare re-run with no arguments remembers all of these without you typing anything again. `publish-ghcr 2.sh` has no equivalent — it's a one-shot publish command, not a "redeploy with memory" one, so it skips straight from step 2 to step 4.

4. **Fallback settings file** — a settings file like `.env.local`/`.env.prod` (see [Environment files explained](#environment-files-explained) below). Checked only if the setting wasn't already resolved by an earlier step.

5. **Interactive prompt, then a hardcoded default or hard error** — if nothing above had an answer, and you're running the script by hand in a real terminal, it asks you directly. Automatically skipped when the script detects it's *not* running in a real terminal (CI, cron, piped input) — so automation never hangs. If skipped (or left blank) and the setting has a sensible default (like `/app` for the working directory), that default is used silently. If there's no safe default (like `DOMAIN`, unless `--local`), it prints a clear error and exits instead of continuing with a bad guess.

Every script's `--help` output documents this same order and lists every setting it accepts — run `./deploy\ 2.sh --help` (etc.) any time as the source of truth.

---

## Environment files explained

| File | Typical purpose | Read by these scripts? |
|---|---|---|
| `.env` | `deploy 2.sh`'s own auto-saved memory of your last run (`DOMAIN`, `NEXT_PUBLIC_SITE_URL`, `CADDYFILE`, `APP_DIR`, `IMAGE` — never `GHCR_USER`/`GHCR_TOKEN`, see below) | Yes, always, automatically — this is the source checked right after CLI flags and raw env vars |
| `.env.local` | Your local dev/default settings (also read by `docker-compose.yml`/`docker-compose 2.yml` and `npm run dev`) | Yes, as a fallback, unless overridden |
| `.env.prod` | Production settings you `scp` to a server | Yes, if you pass `--env-file .env.prod` (or set `ENV_FILE_PATH=.env.prod`) |
| `.env.example` | Template only, never read by any script | No |

**How to pick which fallback file `deploy 2.sh` reads:**
```bash
--env-file .env.prod                    # CLI flag, highest priority (of the fallback tier)
# -- or --
ENV_FILE_PATH=.env.prod ./deploy\ 2.sh   # environment variable, same effect
```
If you don't specify anything, it defaults to `.env.local`. If that file doesn't exist, it's silently skipped — not an error.

> ⚠️ **Security note:** Prefer passing secrets like `GITHUB_TOKEN` as a real (unexported-to-disk) environment variable or a CI secret, rather than writing them into a file. If you do put a token in a file, keep it out of version control — this repo's `.gitignore` already excludes all `.env*` files except `.env.example`.

---

## `deploy 2.sh`

Full production stack (nginx + Caddy for automatic HTTPS + the app, optionally a Cloudflare Tunnel). This one is special: it has **two extra**, higher-priority input sources compared to `publish-ghcr 2.sh` — a raw-env-var check and its own auto-saved settings file (`.env`).

| Setting | CLI flag / positional arg | Source key | Prompted? | Default (if nothing set) |
|---|---|---|---|---|
| Domain | `<domain>` (positional) | `DOMAIN` (in `.env`, see below) | Yes (unless `--local`) | *(none — required unless `--local`, which defaults to `localhost`)* |
| Site URL | `[next-public-site-url]` (positional) | `NEXT_PUBLIC_SITE_URL` (in `.env`) | Yes | `https://<domain>` (derived) |
| Container-internal working directory | `--app-dir DIR` | `APP_DIR` (in `.env`) | Yes | `/app` |
| Local self-signed testing mode | `--local` | *(boolean flag)* | — | off |
| Cloudflare named tunnel | `--tunnel` | *(boolean flag)* | — | off |
| Cloudflare quick tunnel | `--quick-tunnel` | *(boolean flag)* | — | off |
| Pull a pre-built image instead of building | `--pull` | *(boolean flag)* | — | off |
| Build locally, push to a registry, then run here too | `--push` | *(boolean flag)* | — | off |
| Registry image reference (only if `--pull`/`--push`) | *(no flag — see below)* | `IMAGE` (in `.env`) | Yes | *(none — required)* |
| GHCR username for registry login (only used with `--push`, optional) | `--ghcr-user USER` | `GHCR_USER` (never persisted — see below) | Conditional *(only if not already logged in — see below)* | *(none — skips login, push attempted as-is)* |
| GHCR token for registry login (only used with `--push`, optional) | `--ghcr-token TOKEN` | `GHCR_TOKEN` (never persisted) | Conditional *(only if not already logged in)* | *(none — skips login)* |
| Fallback settings file to read | `--env-file PATH` | `ENV_FILE_PATH` | — | `.env.local` |
| Skip starting the stack (build/pull/push only) | `--no-up` | *(boolean flag)* | — | off |

**This script's resolution order has FIVE tiers:**
1. CLI flag / positional arg
2. Raw already-exported env var, e.g. `export DOMAIN=your-domain.com` (or `DOMAIN=your-domain.com ./deploy\ 2.sh`) — checked *before* the script's own remembered state, so you can override a single run without changing what gets saved for next time
3. **This script's own state file (`.env`)** — automatically written after every successful run, so a bare `./deploy\ 2.sh` re-run remembers your last domain/image/app-dir without you typing anything
4. The general fallback settings file (`--env-file`/`.env.local`) — useful for pre-seeding a fresh checkout before you've ever run the script
5. Interactive prompt, then hardcoded default or hard error

> **Gotcha:** each setting is resolved and persisted independently, so changing `DOMAIN` on a re-run does **not** automatically update a previously-saved `NEXT_PUBLIC_SITE_URL` — pass both explicitly (`./deploy\ 2.sh new-domain.com https://new-domain.com`) or edit `.env` directly if you want them to move together.

> **Note:** `GHCR_USER`/`GHCR_TOKEN` are deliberately **excluded** from step 3 (never written to `.env`), even though every other resolved setting is. Writing registry credentials into a script-managed plaintext file is a real credential-leak risk, so they keep their own separate conditional chain instead (below).

**`GHCR_USER`/`GHCR_TOKEN` (only relevant with `--push`) use their own conditional chain**, same as `deploy.sh`:
1. **Already logged in?** — if `docker`'s config already has an auth entry for the target registry, login is skipped entirely.
2. **CLI flag / env var / `.env`/`.env.local`** — checked if not already logged in.
3. **Interactive prompt** — only if still unset, not already logged in, and running in a real terminal (leave username blank to skip login and push anyway).
4. **Skip silently** — non-interactive with nothing provided; `docker compose push` reports its own auth error if login was actually needed.

**`--app-dir` / `APP_DIR` — what it actually affects, and when you need it:**
- Forwarded as `docker-compose 2.yml`'s `APP_DIR` build arg — the container's internal `WORKDIR` (see the Dockerfile). Only takes effect when **building** (`docker compose build`, i.e. no `--pull`, or `--push`). It's inert on a plain `--pull`, since the Dockerfile isn't invoked — the image was already built wherever `scripts/publish-ghcr.sh`/`deploy 2.sh --push` ran.
- Also drives the resume-cache volume mount path, the Next.js image-cache `tmpfs` mount, and the `RESUME_CACHE_FILE` default in `docker-compose 2.yml` — these apply on **every** run, `--pull` included, because they're just runtime container paths that must match whatever `WORKDIR` the image you're running actually has baked in.
- **For a typical `--pull`-only deploy target: leave this unset.** As long as the image you're pulling was built with the default `/app` (the normal case — `APP_DIR` is meant to be a rarely-touched override), everything lines up automatically with no flags needed.
- Only set `--app-dir` if the image you're pulling was itself built with a **non-default** `APP_DIR` — in which case pass the *same* value here so the volume/cache mounts match. Once set, it's remembered in `.env` like `DOMAIN`/`IMAGE`, so future bare re-runs (including `--pull`) keep using it automatically.

**Examples:**
```bash
# First run — you'll be prompted for anything not passed as an arg
./deploy\ 2.sh your-domain.com

# Later — no arguments needed, it remembers the domain from step above
./deploy\ 2.sh

# Local self-signed testing, no domain/DNS needed at all
./deploy\ 2.sh --local

# Pull a pre-built image (the common case — APP_DIR left at its /app default)
IMAGE=ghcr.io/<owner>/rohit-portfolio:latest ./deploy\ 2.sh --pull your-domain.com

# Pull an image that was built with a custom APP_DIR — must match here too
IMAGE=ghcr.io/<owner>/rohit-portfolio:latest ./deploy\ 2.sh --pull your-domain.com --app-dir /srv/app

# Build here, push to a registry, AND run here too
IMAGE=ghcr.io/<owner>/rohit-portfolio:latest ./deploy\ 2.sh --push your-domain.com

# Build/push the image only, without starting the stack here
IMAGE=ghcr.io/<owner>/rohit-portfolio:latest ./deploy\ 2.sh --push --no-up your-domain.com
```

`--tunnel` and `--quick-tunnel` are mutually exclusive. Run `./deploy\ 2.sh --help` for the always-up-to-date reference (the space in the filename needs escaping or quoting on the command line).

---

## `publish-ghcr 2.sh`

A more generic GHCR publisher — plain `docker build`/`push` (no `docker-compose.yml` dependency), with extra flexibility like custom build args and Dockerfile paths.

| Setting | CLI flag | Env var / `.env` key | Prompted? | Default (if nothing set) |
|---|---|---|---|---|
| GitHub username | `--username U` | `GITHUB_USERNAME` | Yes | *(none — required)* |
| GitHub token | `--token PAT` | `GITHUB_TOKEN` | Yes (hidden input) | *(none — required)* |
| Repo name (optional path segment) | `--repo REPO` | `REPO_NAME` | Yes | *(blank — optional, see below)* |
| Image name | `--image-name NAME` | `IMAGE_NAME` | Yes | *(none — required)* |
| Image tag | `--tag TAG` | `IMAGE_TAG` | Yes | `latest` |
| Path to Dockerfile's folder | `--path PATH` | `DOCKER_PATH` | Yes | `.` (current directory) |
| Extra `docker build --build-arg` values | `--build-args "K=V K2=V2"` | `BUILD_ARGS_INPUT` | Yes | *(blank — optional)* |
| Settings file to read | `--env-file PATH` | `ENV_FILE_PATH` | — | `.env.local` |

**`REPO_NAME` controls the image path shape:**
- Left blank → `ghcr.io/USERNAME/IMAGE_NAME:TAG` (2-segment, simplest — good for single-image repos)
- Set → `ghcr.io/USERNAME/REPO_NAME/IMAGE_NAME:TAG` (3-segment — useful if one repo publishes multiple images)

**This script has no dedicated `--app-dir` flag** (unlike `scripts/publish-ghcr.sh`) — it doesn't read `docker-compose.yml` at all, so there's no single place it "knows" to forward `APP_DIR` from. If you need a non-default working directory, pass it through the generic `--build-args` flag instead:
```bash
./publish-ghcr\ 2.sh --username myuser --image-name my-app --build-args "APP_DIR=/srv/app"
```
Whatever value you use here **must match** the `--app-dir`/`APP_DIR` you later set on `deploy 2.sh --pull`, otherwise the runtime volume/cache mounts won't line up with the image's actual `WORKDIR`.

**Examples:**
```bash
./publish-ghcr\ 2.sh --username myuser --image-name my-app --tag v1.2.0
GITHUB_USERNAME=myuser GITHUB_TOKEN=ghp_xxx IMAGE_NAME=my-app ./publish-ghcr\ 2.sh   # no prompts
```

Run `./publish-ghcr\ 2.sh --help` for the always-up-to-date reference (the space in the filename needs escaping or quoting on the command line).

---

## Quick troubleshooting

- **"X is required" error, even though I set it** — check you didn't typo the flag/variable name (see the tables above), and that you're not accidentally overriding it with an empty CLI flag (an empty flag value always beats a non-empty environment variable/file value).
- **Script isn't prompting me at all, just errors out** — you're probably running it with input piped in or from a non-interactive shell (e.g. inside another script, SSH `-n`, or CI). Pass the missing value explicitly as a flag or environment variable instead.
- **`deploy 2.sh` isn't picking up what I put in `.env.local`** — check its own `.env` file first (`cat .env`); if that already has the same key from a previous run, it wins over `.env.local`. Edit `.env` directly, or delete the key from it, to let `.env.local`'s value take effect.
- **I changed a value but a re-run still uses the old one** — the resolved value from *every* successful `deploy 2.sh` run is saved back into `.env` (except `GHCR_USER`/`GHCR_TOKEN`, which are never persisted). Pass the new value as a CLI flag or raw env var for one run, or edit/delete the key directly in `.env`, to override the remembered value.
- **`DOMAIN` changed but `NEXT_PUBLIC_SITE_URL` didn't** — expected: each setting is resolved and persisted independently, so a new domain doesn't automatically update a previously-saved site URL. Pass both explicitly, or edit `.env`, to keep them in sync.
- **Do `GHCR_USER`/`GHCR_TOKEN` ever get saved to `.env`?** — No, never, even though every other resolved setting is. This is intentional — see the security note in the `deploy 2.sh` section above.
- **Resume cache/photo cache seems to disappear after a `--pull` deploy** — almost always an `APP_DIR` mismatch: the pulled image was built with a different `APP_DIR` than what's in this host's `.env`/`.env.local`. Set `--app-dir` to match whatever the publisher used, or rebuild/republish with the default `/app` if you don't actually need a custom path.
