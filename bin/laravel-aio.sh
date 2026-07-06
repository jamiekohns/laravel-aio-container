#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${LARAVEL_AIO_COMPOSE_FILE:-${REPO_ROOT}/compose.yaml}"
PROJECTS_DIR="${LARAVEL_AIO_PROJECTS_DIR:-$HOME/laravel-projects}"
PROJECT_NAME="laravel-aio"

log() { printf '[laravel-aio] %s\n' "$*"; }
die() { printf '[laravel-aio] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: laravel-aio <command> [options]

Commands:
  up                  Start Traefik + Portainer stack
  down                Stop stack
  status              Show service/container status
  logs [service]      Show logs for all services or one service
  new <project-name>  Create a new Laravel project under ~/laravel-projects
  help                Show this help
EOF
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
  docker info >/dev/null 2>&1 || die "cannot connect to Docker daemon; ensure Docker is running"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin not available"
}

compose_cmd() {
  docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" "$@"
}

create_new_project() {
  local project_name="${1:-}"
  [ -n "$project_name" ] || die "project name required. Example: laravel-aio new my-app"
  case "$project_name" in
    *[!a-zA-Z0-9._-]*)
      die "project name can only contain letters, numbers, dot, underscore, and dash"
      ;;
  esac

  mkdir -p "$PROJECTS_DIR"
  local target_dir="$PROJECTS_DIR/$project_name"
  if [ -e "$target_dir" ]; then
    die "target directory already exists: $target_dir"
  fi

  log "Creating Laravel project at $target_dir ..."
  docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$PROJECTS_DIR:/app" \
    -w /app \
    composer:2 \
    create-project --prefer-dist laravel/laravel "$project_name"

  log "Project created."
  echo "Path: $target_dir"
}

main() {
  local cmd="${1:-help}"
  if [ ! -f "$COMPOSE_FILE" ]; then
    die "compose file not found: $COMPOSE_FILE"
  fi

  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    up)
      require_docker
      compose_cmd up -d
      ;;
    down)
      require_docker
      compose_cmd down
      ;;
    status)
      require_docker
      compose_cmd ps
      ;;
    logs)
      require_docker
      if [ -n "${2:-}" ]; then
        compose_cmd logs "$2"
      else
        compose_cmd logs
      fi
      ;;
    new)
      require_docker
      create_new_project "${2:-}"
      ;;
    *)
      usage
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
