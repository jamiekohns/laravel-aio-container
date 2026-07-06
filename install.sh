#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-$HOME}"

REPO_URL="${LARAVEL_AIO_REPO_URL:-https://github.com/jamiekohns/laravel-aio-container.git}"
INSTALL_DIR="${LARAVEL_AIO_DIR:-$TARGET_HOME/.laravel-aio-container}"
ENV_FILE="$TARGET_HOME/.laravel_aio_env.sh"
BASHRC_FILE="$TARGET_HOME/.bashrc"
SOURCE_LINE='[ -f "$HOME/.laravel_aio_env.sh" ] && source "$HOME/.laravel_aio_env.sh"'

GROUP_CHANGED=0

log() { printf '[laravel-aio] %s\n' "$*"; }
warn() { printf '[laravel-aio] warning: %s\n' "$*" >&2; }
die() { printf '[laravel-aio] error: %s\n' "$*" >&2; exit 1; }

run_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "this step requires root privileges; install sudo or run as root"
  fi
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null
}

is_wsl2() {
  grep -qi 'wsl2' /proc/sys/kernel/osrelease 2>/dev/null || grep -qi 'wsl2' /proc/version 2>/dev/null
}

ensure_base_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v git >/dev/null 2>&1 || missing+=(git)
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing missing base packages: ${missing[*]}"
    run_root apt-get update
    run_root apt-get install -y "${missing[@]}"
  fi
}

check_platform() {
  if [ ! -f /etc/os-release ]; then
    die "cannot detect operating system (/etc/os-release not found)"
  fi
  # shellcheck source=/etc/os-release
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    die "unsupported distro '${ID:-unknown}'. This installer currently supports Ubuntu on WSL2."
  fi
  if ! is_wsl; then
    die "WSL environment not detected. This installer is designed for Ubuntu on WSL2."
  fi
  if ! is_wsl2; then
    die "WSL2 not detected. Please upgrade your distro to WSL2 before running this installer."
  fi
}

docker_usable() {
  command -v docker >/dev/null 2>&1 &&
    docker info >/dev/null 2>&1 &&
    docker compose version >/dev/null 2>&1
}

install_docker_if_needed() {
  if docker_usable; then
    log "Docker Engine and Compose plugin are already usable; skipping Docker installation."
    return 0
  fi

  log "Installing Docker Engine and Compose plugin from official Docker Ubuntu repository..."
  run_root apt-get update
  run_root apt-get install -y ca-certificates curl git gnupg

  run_root install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | run_root tee /etc/apt/keyrings/docker.asc >/dev/null
    run_root chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local codename arch repo_line
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"
  if [ ! -f /etc/apt/sources.list.d/docker.list ] || ! grep -Fxq "$repo_line" /etc/apt/sources.list.d/docker.list; then
    printf '%s\n' "$repo_line" | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  fi

  run_root apt-get update
  run_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

configure_docker_group() {
  if ! getent group docker >/dev/null 2>&1; then
    run_root groupadd docker
  fi
  if ! id -nG "$TARGET_USER" | grep -qw docker; then
    run_root usermod -aG docker "$TARGET_USER"
    GROUP_CHANGED=1
  fi
}

start_docker_service() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if run_root systemctl enable --now docker >/dev/null 2>&1; then
      log "Docker service enabled and started with systemd."
    else
      warn "Could not start Docker with systemd. You may need to run: sudo systemctl enable --now docker"
    fi
  else
    warn "systemd is not available in this WSL distro. Enable systemd in /etc/wsl.conf and restart WSL, then run: sudo service docker start"
  fi
}

ensure_repo_checkout() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "Updating existing repo at $INSTALL_DIR..."
    if ! git -C "$INSTALL_DIR" pull --ff-only; then
      die "could not fast-forward update at $INSTALL_DIR (local changes or divergent history). Resolve manually, then re-run."
    fi
    return 0
  fi
  if [ -e "$INSTALL_DIR" ] && [ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
    die "target path exists and is not empty: $INSTALL_DIR. Remove it or set LARAVEL_AIO_DIR to a different location."
  fi
  log "Cloning repository to $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
}

init_env() {
  if [ -f "$INSTALL_DIR/.env.example" ] && [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    log "Initialized $INSTALL_DIR/.env from .env.example"
  fi
}

read_projects_dir() {
  local default_dir="$TARGET_HOME/laravel-projects"
  local configured
  configured="$(grep -E '^LARAVEL_AIO_PROJECTS_DIR=' "$INSTALL_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  if [ -n "$configured" ]; then
    configured="${configured%\"}"
    configured="${configured#\"}"
    configured="${configured%\'}"
    configured="${configured#\'}"
    configured="${configured//\$HOME/$TARGET_HOME}"
    case "$configured" in
      "~/"*) configured="$TARGET_HOME/${configured#~/}" ;;
      "~") configured="$TARGET_HOME" ;;
    esac
    printf '%s\n' "$configured"
  else
    printf '%s\n' "$default_dir"
  fi
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    run_root docker "$@"
  fi
}

start_core_services() {
  local compose_file="$INSTALL_DIR/compose.yaml"
  [ -f "$compose_file" ] || die "compose file missing at $compose_file"
  log "Starting core services (Traefik + Portainer)..."
  docker_cmd compose -f "$compose_file" --project-name laravel-aio up -d
}

install_shell_integration() {
  touch "$ENV_FILE"
  if ! grep -q 'laravel-aio managed block' "$ENV_FILE"; then
    cat >>"$ENV_FILE" <<EOF
# laravel-aio managed block
export LARAVEL_AIO_DIR="${INSTALL_DIR}"
laravel-aio() {
  "\${LARAVEL_AIO_DIR}/bin/laravel-aio.sh" "\$@"
}
# end laravel-aio managed block
EOF
  fi

  touch "$BASHRC_FILE"
  if ! grep -Fxq "$SOURCE_LINE" "$BASHRC_FILE"; then
    printf '\n%s\n' "$SOURCE_LINE" >>"$BASHRC_FILE"
  fi
}

print_summary() {
  local projects_dir="$1"
  log "Install complete."
  echo
  echo "Laravel AIO is installed at: $INSTALL_DIR"
  echo "Projects directory: $projects_dir"
  echo "Traefik dashboard: http://localhost:8080"
  echo "Portainer:         http://localhost:9000"
  echo
  echo "Next steps:"
  echo "  - Reload your shell: source \"$BASHRC_FILE\""
  if [ "$GROUP_CHANGED" -eq 1 ]; then
    echo "  - Docker group membership changed. Open a new terminal (or run: newgrp docker)"
  fi
  echo "  - Start services: laravel-aio up"
  echo "  - Create a project: laravel-aio new my-app"
}

main() {
  check_platform
  ensure_base_tools
  install_docker_if_needed
  configure_docker_group
  start_docker_service
  ensure_repo_checkout
  init_env
  mkdir -p "$(read_projects_dir)"
  start_core_services
  install_shell_integration
  print_summary "$(read_projects_dir)"
}

main "$@"
