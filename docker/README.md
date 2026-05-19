# Docker image

Fat dev-tooling image. Pulled by the `scripts/limousine` wrapper and run with a
read/write bind mount to your workspace tree + the host's docker socket so the
service commands in your `limousine.proj` files run as if they were on the host.

## Tools baked in (pinned in `docker/Dockerfile`)

| Tool         | Version (default) | Why                                                       |
|--------------|-------------------|-----------------------------------------------------------|
| Flutter      | 3.41.9            | builds the web client + native server binary at image build time |
| Node + npm   | 22.13.0           | `studio-frontend/web` runs `npm run dev-*`                |
| uv           | 0.8.4             | every Python service (`mgmt-api`, `auth-core`, `continuum`, …) starts with `uv run uvicorn …` |
| kubectl      | 1.32.2            | `mgmt-api/k8s-sync-worker`, port-forwards, rds-tunnel pod |
| AWS CLI v2   | 2.22.0            | `aws sso login` for the k8s cluster                       |
| docker CLI   | 27.5.1            | `mgmt-api` + `continuum` shell out to `docker exec -i pattern-postgres psql …` |
| NATS CLI     | 0.2.3             | `mgmt-api/nats-sync-request-peek` runs `nats sub …`       |
| python-dotenv | (cli, latest)    | `pa-agent-supervisor` starts with `dotenv -f .env.sessions run …` |
| git, openssh, jq, build-essential | (apt) | clone, ssh-agent forwarding, npm postinstall scripts, uv native deps |

Bump versions in the `ARG …` lines at the top of `docker/Dockerfile` and rebuild.

## Running

```bash
scripts/limousine /abs/path/to/foo.wksp
```

The wrapper bind-mounts:
- The parent directory of the `.wksp` (or `$LIMOUSINE_MOUNT_ROOT`) at the *same path* inside the container — so `docker run -v "$(pwd):/data"` from inside a service still resolves to a real host path.
- `/var/run/docker.sock` so the CLI in-container drives the host daemon.
- `~/.aws`, `~/.kube`, `~/.config/gcloud`, `~/.ssh` (ro), `~/.docker`, `~/.gitconfig` so cloud and git auth Just Work.
- `$SSH_AUTH_SOCK` if present, for `git+ssh://` clones.

`--user $(id -u):$(id -g)` keeps files the container writes owned by you. On
Linux, the wrapper also `--group-add`s the docker socket's GID so the non-root
container user can still talk to it.

## Building locally

```bash
docker buildx build \
  --platform linux/amd64 \
  --tag limousine:dev \
  --load \
  -f docker/Dockerfile \
  .
LIMOUSINE_IMAGE=limousine:dev scripts/limousine /abs/path/to/foo.wksp
```

For a multi-arch build (matches the CI workflow), drop `--load` and add
`--push` to a registry.

## Publishing

`/.github/workflows/docker.yml` builds and pushes to
`ghcr.io/<your-org>/limousine` on every push to `main` (and the
`feature/web-server` branch during the migration). No secret needed beyond the
default `GITHUB_TOKEN` — the workflow has `packages: write` already declared.

GHCR is free for public packages (unlimited storage + bandwidth). After the
first push, mark the package public:
**github.com/<org>/<repo>/pkgs/container/limousine → Package settings →
Change visibility → Public**.
