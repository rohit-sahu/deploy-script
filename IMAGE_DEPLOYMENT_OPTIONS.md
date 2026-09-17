# Getting the `web` Image onto a Deploy Target

`deploy.sh` supports two ways to get the app's Docker image running on a server: build it there, or pull a pre-built one. This is reference material for choosing between them — see [PRODUCTION_DEPLOYMENT.md](./PRODUCTION_DEPLOYMENT.md) for the full deploy checklist.

## Option 1 — Build on the server directly (default, no registry needed)

```bash
./deploy.sh your-domain.com
```

Runs `docker compose build` on the target machine itself. Simplest option, no registry account of any kind required. Best for a single server, since build time/CPU happens on the same box serving traffic during that build.

## Option 2 — Docker Hub (free)

```bash
docker login
docker build -t yourusername/rohit-portfolio:latest .
docker push yourusername/rohit-portfolio:latest

# on the server:
IMAGE=yourusername/rohit-portfolio:latest ./deploy.sh --pull your-domain.com
```

Free tier covers public repos (and one private repo). No cloud-provider-specific setup.

## Option 3 — GitHub Container Registry (ghcr.io, free)

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u yourusername --password-stdin
docker build -t ghcr.io/yourusername/rohit-portfolio:latest .
docker push ghcr.io/yourusername/rohit-portfolio:latest

# on the server:
IMAGE=ghcr.io/yourusername/rohit-portfolio:latest ./deploy.sh --pull your-domain.com
```

Convenient if the repo is already hosted on GitHub — reuses the same account/token.

## Option 4 — AWS ECR

```bash
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
docker build -t <account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest .
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest

# on the server:
IMAGE=<account-id>.dkr.ecr.<region>.amazonaws.com/rohit-portfolio:latest ./deploy.sh --pull your-domain.com
```

Requires an AWS account with ECR set up (repo created, IAM permissions for push/pull). Worth it when already deep in AWS tooling or deploying to multiple instances/an ASG.

## Option 5 — No registry, transfer the image as a file

```bash
docker build -t rohit-portfolio:latest .
or
docker build -t rohit-portfolio:latest --build-arg NEXT_PUBLIC_SITE_URL=https://rohitkumar.skytech.in .
docker save rohit-portfolio:latest | gzip > image.tar.gz
scp image.tar.gz user@server:~/
or
scp -i "/path/to/private-key.pem" /path/to/local/image.tar.gz username@server_ip:/path/to/remote/directory/
or
scp -i "/path/to/private-key.pem" /path/to/local/image.tar.gz username@server_ip:/tmp
In Server,
ls -l /tmp/image.tar.gz
sudo mv /tmp/image.tar.gz /var/www/portfolio/
ssh user@server 'gunzip -c image.tar.gz | docker load'
sudo docker images
```

Then run `./deploy.sh your-domain.com` on the server with no `--pull`/`IMAGE` — the image is already loaded locally under the tag `docker-compose.yml` defaults to (`rohit-portfolio:latest`). No account/registry of any kind needed, at the cost of a manual transfer step per deploy.

## Which to pick

- **Single server, want the least moving parts:** Option 1 (build on server).
- **Want to build once and redeploy the same image later without rebuilding:** Option 2 or 3 (both free, no cloud-provider account needed).
- **Already using AWS for other infra / deploying to multiple instances:** Option 4 (ECR).
- **No registry account at all, one-off transfer is fine:** Option 5 (`docker save`/`load`).
