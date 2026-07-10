For daily Laravel development, this repository provides a one-command Ubuntu-on-WSL2 installer that sets up Docker Engine (if needed), Traefik, Portainer, and a simple command wrapper for stack management and project scaffolding.

## One-command install (Ubuntu on WSL2)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jamiekohns/laravel-aio-container/main/install.sh) --project-name my-app
```

Safer two-step alternative:

```bash
curl -fsSLo /tmp/laravel-aio-install.sh https://raw.githubusercontent.com/jamiekohns/laravel-aio-container/main/install.sh
less /tmp/laravel-aio-install.sh
bash /tmp/laravel-aio-install.sh --project-name my-app
```

The installer is idempotent and safe to re-run.

### `--project-name` argument

Pass `--project-name <name>` to set the name used for the Laravel container and its Traefik hostname.
The container will be named `<name>` and accessible at `http://<name>.localhost`.
If omitted, the default name `laravel-app` is used.

Names may contain letters, numbers, and dashes only.

## What the installer does

- Verifies Ubuntu on WSL2
- Installs Docker Engine + Docker Compose plugin from Docker's official Ubuntu apt repo (only if needed)
- Adds your user to the `docker` group (if needed)
- Starts/enables Docker service when systemd is available
- Clones/updates the repo at `~/.laravel-aio-container`
- Initializes `.env` from `.env.example` when missing
- Writes `PROJECT_NAME` (and `APP_DIR`) to `.env` based on `--project-name`
- Builds the `laravel-aio` Docker image from the repo's `Dockerfile`
- Starts Traefik + Portainer + the Laravel container with Docker Compose
- Installs shell integration:
  - creates `~/.laravel_aio_env.sh`
  - adds one guarded source line to `~/.bashrc`

## Defaults

- Install location: `~/.laravel-aio-container`
- Laravel projects path: `~/laravel-projects` (override with `LARAVEL_AIO_PROJECTS_DIR` in `.env`)
- Project name: `laravel-app` (override with `--project-name` or `PROJECT_NAME` in `.env`)
- App directory: `~/laravel-projects/<project-name>` (override with `APP_DIR` in `.env`)
- Traefik HTTP entrypoint: `http://localhost:80`
- Traefik dashboard: `http://localhost:8080` (`TRAEFIK_INSECURE_DASHBOARD=true` by default for local dev; do not expose publicly)
- Portainer: `http://localhost:9000`
- Laravel app: `http://<project-name>.localhost`

## Commands

After installation, reload your shell:

```bash
source ~/.bashrc
```

Then use:

```bash
laravel-aio up
laravel-aio down
laravel-aio status
laravel-aio logs
laravel-aio logs portainer
laravel-aio new my-app
```

## WSL caveats

- If your distro does not have systemd enabled, Docker service auto-start is limited.
- If your user was newly added to the `docker` group, open a new terminal (or run `newgrp docker`) before using Docker without `sudo`.

## Troubleshooting (quick)

- `docker: command not found`  
  Re-run installer and ensure apt steps completed.

- `cannot connect to Docker daemon`  
  On systemd-enabled WSL: `sudo systemctl enable --now docker`  
  Without systemd: `sudo service docker start`

- `laravel-aio: command not found`  
  Run `source ~/.bashrc` or open a new terminal.

## Security considerations

- `TRAEFIK_INSECURE_DASHBOARD=true` exposes the Traefik dashboard without auth; keep this local-only and never expose `:8080` externally.
- If you need broader network access, set `TRAEFIK_INSECURE_DASHBOARD=false` and configure authenticated access before exposing Traefik.
- Portainer uses Docker socket access for management operations; treat this setup as trusted local development only.

## Existing container image and wrapper notes

The repository still includes the original Dockerfile and `bash/scripts/docker.sh` workflow for manual image/container management.
