# Getting the `web` Image onto a Deploy Target

`deploy.sh` supports three ways to get the app's Docker image running on a server: build it there, build-and-push-and-run it there (`--push`), or pull a pre-built one (`--pull`). This is reference material for choosing between them — see [PRODUCTION_DEPLOYMENT.md](./PRODUCTION_DEPLOYMENT.md) for the full deploy checklist.

## Option 1 — Build on the server directly (default, no registry needed)

```bash
./deploy.sh https://your-domain.com
```

Runs `docker compose build` on the target machine itself. Simplest option, no registry account of any kind required. Best for a single server, since build time/CPU happens on the same box serving traffic during that build.

## Option 2 — Docker Hub (free)

```bash
docker login
docker build -t yourusername/rohit-portfolio:latest .
docker push yourusername/rohit-portfolio:latest

# on the server:
IMAGE=yourusername/rohit-portfolio:latest ./deploy.sh --pull
```

Free tier covers public repos (and one private repo). No cloud-provider-specific setup.

## Option 3 — GitHub Container Registry (ghcr.io, free) — recommended

Two ways to use GHCR with this repo, depending on where you're building:

**3a. Build on a separate machine (laptop/CI), push, don't run it there:**

```bash
./publish-ghcr.sh
# prompts for: GitHub owner, a PAT with write:packages scope, image name
# (default rohit-portfolio), tag (default latest), and NEXT_PUBLIC_SITE_URL

# on the server:
IMAGE=ghcr.io/<owner>/rohit-portfolio:latest ./deploy.sh --pull
```

**3b. Build on the server itself, push to GHCR *and* run it there in one step:**

```bash
IMAGE=ghcr.io/<owner>/rohit-portfolio:latest ./deploy.sh --push
```

Both `publish-ghcr.sh` and `deploy.sh --push` delegate to the same `docker compose build` / `docker compose push web` commands (driven by the `IMAGE`/`NEXT_PUBLIC_SITE_URL` env vars docker-compose.yml already reads) — there's only one place that knows how to build/tag this image, not two separate implementations. `--push` additionally logs in for you if `GHCR_USER`/`GHCR_TOKEN` are set (otherwise it reuses an existing `docker login` session).

Or do it fully manually, without either script:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u yourusername --password-stdin
docker build --build-arg NEXT_PUBLIC_SITE_URL=https://your-domain.com -t ghcr.io/yourusername/rohit-portfolio:latest .
docker push ghcr.io/yourusername/rohit-portfolio:latest

# on the server:
IMAGE=ghcr.io/yourusername/rohit-portfolio:latest ./deploy.sh --pull
```

Convenient if the repo is already hosted on GitHub — reuses the same account/token. This is the recommended registry option for this project.

## Option 4 — AWS ECR

```bash
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
docker build -t <account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest .
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest

# on the server:
IMAGE=<account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest ./deploy.sh --pull
```

Requires an AWS account with ECR set up (repo created, IAM permissions for push/pull). Worth it when already deep in AWS tooling or deploying to multiple instances/an ASG.

## Option 5 — No registry, transfer the image as a file

```bash
docker build -t rohit-portfolio:latest --build-arg NEXT_PUBLIC_SITE_URL=https://your-domain.com .
docker save rohit-portfolio:latest | gzip > image.tar.gz
scp image.tar.gz user@server:~/
# on the server:
gunzip -c image.tar.gz | docker load
docker images
rm image.tar.gz   # don't leave transfer artifacts lying around on either side
```

Then run `./deploy.sh` on the server with no `--pull`/`--push`/`IMAGE` — the image is already loaded locally under the tag `docker-compose.yml` defaults to (`rohit-portfolio:latest`). No account/registry of any kind needed, at the cost of a manual transfer step per deploy.

## Which to pick

- **Single server, want the least moving parts:** Option 1 (build on server).
- **Building on a laptop/CI, deploying to one or more separate servers:** Option 3a (GHCR via `publish-ghcr.sh`, then `--pull` on each server) — recommended.
- **Single server that builds its own image but you still want a registry backup/copy:** Option 3b (`deploy.sh --push`).
- **Already using AWS for other infra / deploying to multiple instances:** Option 4 (ECR).
- **No registry account at all, one-off transfer is fine:** Option 5 (`docker save`/`load`).

## GHCR-related environment variables

| Variable | Used by | Purpose |
|---|---|---|
| `IMAGE` | `deploy.sh` (`--pull`/`--push`), `publish-ghcr.sh` (set automatically) | Full registry reference, e.g. `ghcr.io/<owner>/rohit-portfolio:latest`. Also read by `docker-compose.yml`'s `image:` field. |
| `GHCR_USER` | `deploy.sh --push` | GHCR username for non-interactive `docker login` (skip if already logged in). |
| `GHCR_TOKEN` | `deploy.sh --push` | GHCR PAT (needs `write:packages`) for non-interactive `docker login`. |
| `NEXT_PUBLIC_SITE_URL` | `deploy.sh`, `publish-ghcr.sh` (prompted) | Baked into the JS bundle at build time via the Dockerfile's build arg. |
| `APP_DIR` | `deploy.sh`, `publish-ghcr.sh` (prompted, default `/app`) | Container-internal working directory, forwarded as a Dockerfile build arg. Also drives the volume mount, cache tmpfs, and `RESUME_CACHE_FILE` default in `docker-compose.yml`, so all of them move together. Rarely needs to change. |

