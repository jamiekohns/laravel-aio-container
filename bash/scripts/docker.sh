# --- docker interactive wrapper: manage containers on the current Docker engine ---

DCONTAINER_CONF_DIR="${HOME}/.local/share/docker"
DCONTAINER_IMAGE="laravel-php83-fpm-nginx-mailparse"
DCONTAINER_NETWORK="web"
DCONTAINER_MIN_PORT=8001
DCONTAINER_MAX_PORT=65535

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# List all containers; prints tab-separated: Names \t State \t Image
__docker_list_containers() {
  docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Image}}' 2>/dev/null
}

# Return the current state string for a container by name/ID
__docker_container_state() {
  local id="$1"
  docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null
}

# Check if a host port is already bound
__docker_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$" && return 0
  fi
  return 1
}

# Find first available host port in DCONTAINER_MIN_PORT..DCONTAINER_MAX_PORT
__docker_find_port() {
  local port
  for ((port=DCONTAINER_MIN_PORT; port<=DCONTAINER_MAX_PORT; port++)); do
    if ! __docker_port_in_use "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

# Write run parameters to a config file
__docker_save_config() {
  local container_name="$1" app_dir="$2" app_subdomain="$3"
  local app_port="$4"       run_image="$5" network="$6"

  mkdir -p "$DCONTAINER_CONF_DIR"
  cat > "${DCONTAINER_CONF_DIR}/${container_name}.conf" <<EOF
CONTAINER_NAME=${container_name}
APP_DIR=${app_dir}
APP_SUBDOMAIN=${app_subdomain}
APP_PORT=${app_port}
RUN_IMAGE=${run_image}
NETWORK_NAME=${network}
EOF
}

# ---------------------------------------------------------------------------
# doctrl run -- launch a new Laravel container
# ---------------------------------------------------------------------------
__doctrl_run() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "doctrl: docker not found in PATH" >&2; return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "doctrl: cannot connect to Docker daemon" >&2; return 1
  fi
  if ! docker image inspect "$DCONTAINER_IMAGE" >/dev/null 2>&1; then
    echo "doctrl: image '$DCONTAINER_IMAGE' not found. Build it first." >&2
    return 1
  fi

  # --- Select APP_DIR from ~/projects subdirectories ---
  local app_dir
  if command -v fzf >/dev/null 2>&1; then
    app_dir="$(
      find "$HOME/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort |
        fzf --prompt="APP_DIR > " --no-multi --height=50% --border \
            --preview 'ls -1 {} 2>/dev/null | head -40'
    )"
    [[ -z "$app_dir" ]] && return 130
  else
    while true; do
      read -r -p "Enter APP_DIR (absolute path to Laravel app): " app_dir
      app_dir="${app_dir%/}"
      [[ -z "$app_dir" ]] && { echo "APP_DIR cannot be empty."; continue; }
      [[ ! -d "$app_dir" ]] && { echo "Directory does not exist: $app_dir"; continue; }
      break
    done
  fi

  if [[ ! -f "$app_dir/artisan" ]]; then
    echo "Warning: '$app_dir/artisan' not found. This may not be a Laravel project."
    read -r -p "Continue anyway? [y/N]: " yn
    case "$yn" in [Yy]*) ;; *) return 130 ;; esac
  fi

  # --- APP_SUBDOMAIN (default: basename of app_dir, lowercased, underscores->hyphens) ---
  local default_subdomain
  default_subdomain="$(basename "$app_dir" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  local app_subdomain
  while true; do
    read -r -p "Enter APP_SUBDOMAIN [${default_subdomain}]: " app_subdomain
    app_subdomain="${app_subdomain:-$default_subdomain}"
    if [[ ! "$app_subdomain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "Use lowercase letters, digits, and hyphens only (must start/end with letter or digit)."
      continue
    fi
    break
  done

  # --- Find a free port ---
  local app_port
  app_port="$(__docker_find_port)" || {
    echo "doctrl: no available port in range ${DCONTAINER_MIN_PORT}-${DCONTAINER_MAX_PORT}" >&2
    return 1
  }

  # --- Avoid container name collision ---
  local container_name="$app_subdomain"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
    container_name="${app_subdomain}-${app_port}"
    echo "Container '$app_subdomain' already exists. Using '$container_name'."
  fi

  # --- Ensure network exists ---
  docker network create "$DCONTAINER_NETWORK" >/dev/null 2>&1 || true

  # --- Launch ---
  docker run -d \
    --name "$container_name" \
    --network "$DCONTAINER_NETWORK" \
    -p "${app_port}:80" \
    -v "${app_dir}:/var/www/html" \
    --restart unless-stopped \
    -l traefik.enable=true \
    -l "traefik.docker.network=${DCONTAINER_NETWORK}" \
    -l "traefik.http.routers.${app_subdomain}.rule=Host(\`${app_subdomain}.localhost\`)" \
    -l "traefik.http.routers.${app_subdomain}.entrypoints=web" \
    -l "traefik.http.services.${app_subdomain}.loadbalancer.server.port=80" \
    "$DCONTAINER_IMAGE"

  __docker_save_config \
    "$container_name" "$app_dir" "$app_subdomain" "$app_port" \
    "$DCONTAINER_IMAGE" "$DCONTAINER_NETWORK"

  echo
  echo "Started container:  $container_name"
  echo "Host port:          $app_port"
  echo "Traefik host:       http://${app_subdomain}.localhost"
  echo "Direct:             http://localhost:${app_port}"
}

# ---------------------------------------------------------------------------
# doctrl reload -- stop, remove, and re-run a saved container
# ---------------------------------------------------------------------------
__doctrl_reload() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "doctrl: docker not found in PATH" >&2; return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "doctrl: cannot connect to Docker daemon" >&2; return 1
  fi

  mkdir -p "$DCONTAINER_CONF_DIR"

  local -a conf_files
  mapfile -t conf_files < <(find "$DCONTAINER_CONF_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | sort)

  if ((${#conf_files[@]} == 0)); then
    echo "doctrl: no saved containers found in $DCONTAINER_CONF_DIR" >&2
    return 1
  fi

  # Build display labels; container name is always first whitespace-delimited token
  local -a labels
  local f key val
  local CONTAINER_NAME APP_DIR APP_PORT
  for f in "${conf_files[@]}"; do
    CONTAINER_NAME="" APP_DIR="" APP_PORT=""
    while IFS='=' read -r key val; do
      case "$key" in
        CONTAINER_NAME) CONTAINER_NAME="$val" ;;
        APP_DIR)        APP_DIR="$val" ;;
        APP_PORT)       APP_PORT="$val" ;;
      esac
    done < "$f"
    labels+=("$(printf '%-25s  port:%-6s  %s' "$CONTAINER_NAME" "$APP_PORT" "$APP_DIR")")
  done

  local chosen_f
  local conf_dir="$DCONTAINER_CONF_DIR"

  if command -v fzf >/dev/null 2>&1; then
    local choice
    choice="$(
      printf "%s\n" "${labels[@]}" |
        fzf --prompt="reload > " --no-multi --height=40% --border \
            --preview "cat \"${conf_dir}/{1}.conf\" 2>/dev/null"
    )"
    [[ -z "$choice" ]] && return 130
    local chosen_name
    chosen_name="$(awk '{print $1}' <<< "$choice")"
    chosen_f="${conf_dir}/${chosen_name}.conf"
  else
    echo
    echo "Saved containers:"
    local i=1
    for lbl in "${labels[@]}"; do
      printf "  %2d) %s\n" "$i" "$lbl"
      ((i++))
    done
    echo
    local idx choice
    while true; do
      read -r -p "Choose (number, blank=cancel): " choice
      [[ -z "$choice" ]] && return 130
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((choice - 1))
        if (( idx >= 0 && idx < ${#conf_files[@]} )); then
          chosen_f="${conf_files[$idx]}"
          break
        fi
        echo "Invalid number."
      else
        echo "Enter a number."
      fi
    done
  fi

  if [[ ! -f "$chosen_f" ]]; then
    echo "doctrl: config file not found: $chosen_f" >&2
    return 1
  fi

  # Load config
  local CONTAINER_NAME APP_DIR APP_SUBDOMAIN APP_PORT RUN_IMAGE NETWORK_NAME
  CONTAINER_NAME="" APP_DIR="" APP_SUBDOMAIN="" APP_PORT="" RUN_IMAGE="" NETWORK_NAME=""
  while IFS='=' read -r key val; do
    case "$key" in
      CONTAINER_NAME) CONTAINER_NAME="$val" ;;
      APP_DIR)        APP_DIR="$val" ;;
      APP_SUBDOMAIN)  APP_SUBDOMAIN="$val" ;;
      APP_PORT)       APP_PORT="$val" ;;
      RUN_IMAGE)      RUN_IMAGE="$val" ;;
      NETWORK_NAME)   NETWORK_NAME="$val" ;;
    esac
  done < "$chosen_f"

  if [[ -z "$CONTAINER_NAME" || -z "$APP_DIR" || -z "$APP_PORT" || -z "$RUN_IMAGE" ]]; then
    echo "doctrl: incomplete config in $chosen_f" >&2
    return 1
  fi

  # Stop and remove if the container currently exists
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "Stopping ${CONTAINER_NAME}..."
    docker stop "$CONTAINER_NAME" >/dev/null
    echo "Removing ${CONTAINER_NAME}..."
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  # Ensure network exists
  docker network create "${NETWORK_NAME:-web}" >/dev/null 2>&1 || true

  # Re-run with saved parameters
  echo "Restarting ${CONTAINER_NAME}..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --network "${NETWORK_NAME:-web}" \
    -p "${APP_PORT}:80" \
    -v "${APP_DIR}:/var/www/html" \
    --restart unless-stopped \
    -l traefik.enable=true \
    -l "traefik.docker.network=${NETWORK_NAME:-web}" \
    -l "traefik.http.routers.${APP_SUBDOMAIN}.rule=Host(\`${APP_SUBDOMAIN}.localhost\`)" \
    -l "traefik.http.routers.${APP_SUBDOMAIN}.entrypoints=web" \
    -l "traefik.http.services.${APP_SUBDOMAIN}.loadbalancer.server.port=80" \
    "$RUN_IMAGE"

  echo
  echo "Reloaded container: $CONTAINER_NAME"
  echo "Host port:          $APP_PORT"
  echo "Traefik host:       http://${APP_SUBDOMAIN}.localhost"
  echo "Direct:             http://localhost:${APP_PORT}"
}

# ---------------------------------------------------------------------------
# doctrl build -- build Laravel Docker images, locating the Dockerfile first
# ---------------------------------------------------------------------------
__doctrl_build() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "doctrl: docker not found in PATH" >&2; return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "doctrl: cannot connect to Docker daemon" >&2; return 1
  fi

  local expected_header="# Laravel PHP 8.3 FPM + Nginx Dockerfile Laravel-php83-fpm-nginx"
  local build_ctx=""
  local saved_ctx_file="${DCONTAINER_CONF_DIR}/laravel-dockerfile-path"

  mkdir -p "$DCONTAINER_CONF_DIR"

  # Re-use previously saved path if the Dockerfile still exists there
  if [[ -f "$saved_ctx_file" ]]; then
    local saved_ctx
    saved_ctx="$(cat "$saved_ctx_file")"
    if [[ -f "${saved_ctx}/Dockerfile" ]]; then
      build_ctx="$saved_ctx"
      echo "Using saved Dockerfile path: ${saved_ctx}/Dockerfile"
    else
      echo "Saved path '${saved_ctx}' no longer valid; searching..."
    fi
  fi

  # Search the filesystem if no saved (or valid) path
  if [[ -z "$build_ctx" ]]; then
    echo "Searching for Dockerfile..."
    local candidate
    while IFS= read -r candidate; do
      if [[ "$(head -n1 "$candidate" 2>/dev/null)" == "$expected_header" ]]; then
        build_ctx="$(dirname "$candidate")"
        echo "Found Dockerfile: $candidate"
        break
      fi
    done < <(find ~ -name "Dockerfile" -type f 2>/dev/null)
  fi

  # Prompt if still not found
  if [[ -z "$build_ctx" ]]; then
    echo "Dockerfile with expected header not found by search."
    while true; do
      read -r -p "Enter full path to the Dockerfile (file or directory): " user_path
      user_path="${user_path%/}"
      if [[ -f "$user_path" && "$(basename "$user_path")" == "Dockerfile" ]]; then
        build_ctx="$(dirname "$user_path")"
        break
      elif [[ -f "${user_path}/Dockerfile" ]]; then
        build_ctx="$user_path"
        break
      else
        echo "No Dockerfile found at '$user_path'. Try again."
      fi
    done
  fi

  # Persist the resolved path for future runs
  echo "$build_ctx" > "$saved_ctx_file"

  echo
  echo "Build context: $build_ctx"
  echo "Images to build:"
  echo "  - laravel-php83-fpm-nginx"
  echo "  - laravel-php83-fpm-nginx-mailparse"
  echo
  read -r -p "Proceed with build? [y/N]: " confirm
  case "$confirm" in [Yy]*) ;; *) echo "Aborted."; return 130 ;; esac
  echo

#   echo "Building laravel-php83-fpm-nginx ..."
#   docker build \
#     -t laravel-php83-fpm-nginx \
#     --build-arg INSTALL_MAILPARSE=false \
#     --build-arg UID="$(id -u)" \
#     --build-arg GID="$(id -g)" \
#     "$build_ctx" || return $?

  echo "Building laravel-php83-fpm-nginx-mailparse ..."
  docker build \
    -t laravel-php83-fpm-nginx-mailparse \
    --build-arg INSTALL_MAILPARSE=true \
    --build-arg UID="$(id -u)" \
    --build-arg GID="$(id -g)" \
    "$build_ctx"
  return $?
}

# ---------------------------------------------------------------------------
# doctrl enter -- open a shell in a running container
# ---------------------------------------------------------------------------
__doctrl_enter() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "doctrl: docker not found in PATH" >&2; return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "doctrl: cannot connect to Docker daemon" >&2; return 1
  fi

  local -a raw_lines
  mapfile -t raw_lines < <(docker ps --format '{{.Names}}\t{{.State}}\t{{.Image}}' 2>/dev/null)

  if ((${#raw_lines[@]} == 0)); then
    echo "doctrl: no running containers found" >&2
    return 1
  fi

  local -a container_names display_lines
  local line name state image
  for line in "${raw_lines[@]}"; do
    IFS=$'\t' read -r name state image <<< "$line"
    container_names+=("$name")
    display_lines+=("$(printf '%-30s  [%-9s]  %s' "$name" "$state" "$image")")
  done

  local chosen_name choice

  if command -v fzf >/dev/null 2>&1; then
    choice="$(
      printf "%s\n" "${display_lines[@]}" |
        fzf --prompt="enter > " --no-multi --height=50% --border \
            --preview 'docker inspect --format "Name:     {{slice .Name 1}}
Image:    {{.Config.Image}}
Status:   {{.State.Status}}
Started:  {{.State.StartedAt}}
IP:       {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" {1} 2>/dev/null'
    )"
    [[ -z "$choice" ]] && return 130
    chosen_name="$(awk '{print $1}' <<< "$choice")"
  else
    echo
    echo "Running containers:"
    local i=1
    for line in "${display_lines[@]}"; do
      printf "  %2d) %s\n" "$i" "$line"
      ((i++))
    done
    echo
    while true; do
      read -r -p "Choose (number, blank=cancel): " choice
      [[ -z "$choice" ]] && return 130
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if (( idx >= 0 && idx < ${#container_names[@]} )); then
          chosen_name="${container_names[$idx]}"
          break
        fi
        echo "Invalid number."
      else
        echo "Enter a number."
      fi
    done
  fi

  local current_state
  current_state="$(__docker_container_state "$chosen_name")"
  if [[ "$current_state" != "running" ]]; then
    echo "doctrl: '${chosen_name}' is no longer running (state: ${current_state})" >&2
    return 1
  fi

  if docker exec "$chosen_name" which bash >/dev/null 2>&1; then
    docker exec -it --user dev -w /var/www/html "$chosen_name" bash
  else
    docker exec -it --user dev -w /var/www/html "$chosen_name" sh
  fi
  return $?
}

# ---------------------------------------------------------------------------
# doctrl code -- open a project directory in VS Code
# ---------------------------------------------------------------------------
__doctrl_code() {
  if ! command -v code >/dev/null 2>&1; then
    echo "doctrl: 'code' not found in PATH" >&2; return 1
  fi

  local project_path="${1:-}"

  if [[ -n "$project_path" ]]; then
    if [[ ! -d "$project_path" ]]; then
      echo "doctrl: directory not found: $project_path" >&2; return 1
    fi
  elif command -v fzf >/dev/null 2>&1; then
    project_path="$(
      find "$HOME/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort |
        fzf --prompt="code > " --no-multi --height=50% --border \
            --preview 'ls -1 {} 2>/dev/null | head -40'
    )"
    [[ -z "$project_path" ]] && return 130
  else
    while true; do
      read -r -p "Enter project path: " project_path
      project_path="${project_path%/}"
      [[ -z "$project_path" ]] && { echo "Path cannot be empty."; continue; }
      [[ ! -d "$project_path" ]] && { echo "Directory does not exist: $project_path"; continue; }
      break
    done
  fi

  code "$project_path"
  return $?
}

# ---------------------------------------------------------------------------
# doctrl artisan -- run php artisan <command> in a running container
# ---------------------------------------------------------------------------
__doctrl_artisan() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "doctrl: docker not found in PATH" >&2; return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "doctrl: cannot connect to Docker daemon" >&2; return 1
  fi

  local container_name="${1:-}"
  shift || true
  local -a artisan_args=("$@")

  # --- Container resolution ---
  if [[ -n "$container_name" ]]; then
    local state
    state="$(__docker_container_state "$container_name")"
    if [[ "$state" != "running" ]]; then
      if [[ -z "$state" ]]; then
        echo "doctrl: container '${container_name}' not found" >&2
      else
        echo "doctrl: container '${container_name}' is not running (state: ${state})" >&2
      fi
      return 1
    fi
  else
    local -a raw_lines
    mapfile -t raw_lines < <(docker ps --format '{{.Names}}\t{{.State}}\t{{.Image}}' 2>/dev/null)

    if ((${#raw_lines[@]} == 0)); then
      echo "doctrl: no running containers found" >&2
      return 1
    fi

    local -a container_names display_lines
    local line name state image
    for line in "${raw_lines[@]}"; do
      IFS=$'\t' read -r name state image <<< "$line"
      container_names+=("$name")
      display_lines+=("$(printf '%-30s  [%-9s]  %s' "$name" "$state" "$image")")
    done

    local choice
    if command -v fzf >/dev/null 2>&1; then
      choice="$(
        printf "%s\n" "${display_lines[@]}" |
          fzf --prompt="artisan > " --no-multi --height=50% --border \
              --preview 'docker inspect --format "Name:     {{slice .Name 1}}
Image:    {{.Config.Image}}
Status:   {{.State.Status}}
Started:  {{.State.StartedAt}}
IP:       {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" {1} 2>/dev/null'
      )"
      [[ -z "$choice" ]] && return 130
      container_name="$(awk '{print $1}' <<< "$choice")"
    else
      echo
      echo "Running containers:"
      local i=1
      for line in "${display_lines[@]}"; do
        printf "  %2d) %s\n" "$i" "$line"
        ((i++))
      done
      echo
      while true; do
        read -r -p "Choose container (number, blank=cancel): " choice
        [[ -z "$choice" ]] && return 130
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local idx=$((choice - 1))
          if (( idx >= 0 && idx < ${#container_names[@]} )); then
            container_name="${container_names[$idx]}"
            break
          fi
          echo "Invalid number."
        else
          echo "Enter a number."
        fi
      done
    fi
  fi

  # --- Artisan command resolution ---
  if ((${#artisan_args[@]} == 0)); then
    if command -v fzf >/dev/null 2>&1; then
      local artisan_cmd
      artisan_cmd="$(
        docker exec --user dev -w /var/www/html "$container_name" \
          php artisan list --format=txt 2>/dev/null \
          | grep -E '^ {1,2}[a-z]' \
          | awk '{print $1}' \
          | fzf --prompt="artisan [${container_name}] > " --no-multi --height=60% --border \
                --preview "docker exec --user dev -w /var/www/html \"${container_name}\" php artisan help {} 2>/dev/null"
      )"
      [[ -z "$artisan_cmd" ]] && return 130
      artisan_args=("$artisan_cmd")
    else
      echo
      echo "Available artisan commands for [${container_name}]:"
      docker exec --user dev -w /var/www/html "$container_name" php artisan 2>/dev/null
      echo
      local artisan_input
      read -r -p "Command to run (blank=cancel): " artisan_input
      [[ -z "$artisan_input" ]] && return 130
      read -ra artisan_args <<< "$artisan_input"
    fi
  fi

  # --- Execute ---
  docker exec -it --user dev -w /var/www/html "$container_name" php artisan "${artisan_args[@]}"
  return $?
}

# ---------------------------------------------------------------------------
# doctrl -- main entry point
# ---------------------------------------------------------------------------
doctrl() {
  local subcmd="${1:-}"

  case "$subcmd" in
    build)
      __doctrl_build
      return $?
      ;;
    run)
      __doctrl_run
      return $?
      ;;
    reload)
      __doctrl_reload
      return $?
      ;;
    enter)
      __doctrl_enter
      return $?
      ;;
    code)
      __doctrl_code "${2:-}"
      return $?
      ;;
    artisan)
      __doctrl_artisan "${2:-}" "${@:3}"
      return $?
      ;;
    "")
      # fall through to interactive container manager
      ;;
    -h|--help|help)
      echo "Usage: doctrl [build|run|reload|enter|artisan|code [path]]"
      echo "  (no args)              -- interactively manage existing containers"
      echo "  build                  -- build Laravel Docker image (searches for Dockerfile)"
      echo "  run                    -- launch a new Laravel container from ~/projects"
      echo "  reload                 -- stop, remove, and re-run a saved container"
      echo "  enter                  -- directly open a shell in a running container"
      echo "  artisan [c [cmd ...]]  -- run php artisan in a container (picker if omitted)"
      echo "  code [path]            -- open a project in VS Code (fzf picker if no path given)"
      return 0
      ;;
    *)
      echo "doctrl: unknown subcommand '$subcmd'" >&2
      echo "Usage: doctrl [build|run|reload|enter|artisan|code [path]]" >&2
      return 1
      ;;
  esac

  # --- Top-level menu (no subcommand) ---
  local -a menu_options menu_descs
  menu_options=("enter" "artisan" "code" "manage" "reload" "run" "build")  # reorder for more common actions
  menu_descs=(
    "enter   -- open a shell in a running container"
    "artisan -- run php artisan in a running container"
    "code    -- open a project directory in VS Code"
    "manage  -- interactively manage existing containers"
    "reload  -- stop, remove, and re-run a saved container"
    "run     -- launch a new Laravel container"
    "build   -- build Laravel Docker image"
  )

  local top_action
  if command -v fzf >/dev/null 2>&1; then
    top_action="$(
      printf "%s\n" "${menu_descs[@]}" |
        fzf --prompt="doctrl > " --no-multi --height=40% --border --no-preview
    )"
    [[ -z "$top_action" ]] && return 130
    top_action="$(awk '{print $1}' <<< "$top_action")"
  else
    echo
    echo "doctrl -- what would you like to do?"
    local i=1
    for desc in "${menu_descs[@]}"; do
      printf "  %2d) %s\n" "$i" "$desc"
      ((i++))
    done
    echo
    local top_choice
    while true; do
      read -r -p "Choose (number, blank=cancel): " top_choice
      [[ -z "$top_choice" ]] && return 130
      if [[ "$top_choice" =~ ^[0-9]+$ ]]; then
        local top_idx=$((top_choice - 1))
        if (( top_idx >= 0 && top_idx < ${#menu_options[@]} )); then
          top_action="${menu_options[$top_idx]}"
          break
        fi
        echo "Invalid number."
      else
        echo "Enter a number."
      fi
    done
  fi

  case "$top_action" in
    build)   __doctrl_build;              return $? ;;
    run)     __doctrl_run;                return $? ;;
    reload)  __doctrl_reload;             return $? ;;
    enter)   __doctrl_enter;              return $? ;;
    artisan) __doctrl_artisan "" "";      return $? ;;
    code)    __doctrl_code "";            return $? ;;
    manage)  ;;  # fall through to interactive container manager
    *)
      echo "doctrl: unknown selection '${top_action}'" >&2
      return 1
      ;;
  esac

  # --- Interactive container manager ---

  # Require docker
  if ! command -v docker >/dev/null 2>&1; then
    echo "doctrl: docker not found in PATH" >&2
    return 1
  fi

  # Check daemon reachability
  if ! docker info >/dev/null 2>&1; then
    echo "doctrl: cannot connect to Docker daemon" >&2
    return 1
  fi

  # Gather all containers
  local -a raw_lines
  mapfile -t raw_lines < <(__docker_list_containers)

  if ((${#raw_lines[@]} == 0)); then
    echo "doctrl: no containers found" >&2
    return 1
  fi

  # Build parallel arrays: names and display strings
  # Container names are always single-word (Docker enforces this)
  local -a container_names display_lines
  local line name state image
  for line in "${raw_lines[@]}"; do
    IFS=$'\t' read -r name state image <<< "$line"
    container_names+=("$name")
    display_lines+=("$(printf '%-30s  [%-9s]  %s' "$name" "$state" "$image")")
  done

  local chosen_name choice

  # --- Container selection ---
  if command -v fzf >/dev/null 2>&1; then
    # {1} is the first whitespace-delimited token = container name (Docker names never contain spaces)
    choice="$(
      printf "%s\n" "${display_lines[@]}" |
        fzf --prompt="container > " --no-multi --height=50% --border \
            --preview 'docker inspect --format "Name:     {{slice .Name 1}}
Image:    {{.Config.Image}}
Status:   {{.State.Status}}
Started:  {{.State.StartedAt}}
IP:       {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" {1} 2>/dev/null'
    )"
    [[ -z "$choice" ]] && return 130
    chosen_name="$(awk '{print $1}' <<< "$choice")"
  else
    # Fallback: numbered menu
    echo
    echo "Docker Containers:"
    local i=1
    for line in "${display_lines[@]}"; do
      printf "  %2d) %s\n" "$i" "$line"
      ((i++))
    done
    echo

    while true; do
      read -r -p "Choose (number, blank=cancel): " choice
      [[ -z "$choice" ]] && return 130

      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if (( idx >= 0 && idx < ${#container_names[@]} )); then
          chosen_name="${container_names[$idx]}"
          break
        fi
        echo "Invalid number."
      else
        echo "Enter a number."
      fi
    done
  fi

  if [[ -z "$chosen_name" ]]; then
    echo "doctrl: could not resolve container" >&2
    return 1
  fi

  # Re-check state (may have changed since listing)
  local chosen_state
  chosen_state="$(__docker_container_state "$chosen_name")"

  # Build state-appropriate action list
  local -a actions
  case "$chosen_state" in
    running)
      actions=("enter" "stop")
      ;;
    exited|created|dead)
      actions=("start")
      ;;
    paused)
      actions=("stop")
      ;;
    *)
      # Transitional or unknown state — offer safe options only
      actions=("start" "stop")
      ;;
  esac

  # --- Action selection ---
  local action
  if command -v fzf >/dev/null 2>&1; then
    action="$(
      printf "%s\n" "${actions[@]}" |
        fzf --prompt="action [${chosen_name}] > " --no-multi --height=20% --border --no-preview
    )"
    [[ -z "$action" ]] && return 130
  else
    echo
    echo "Actions for: ${chosen_name}  [${chosen_state}]"
    local i=1
    for a in "${actions[@]}"; do
      printf "  %2d) %s\n" "$i" "$a"
      ((i++))
    done
    echo

    while true; do
      read -r -p "Choose action (number, blank=cancel): " choice
      [[ -z "$choice" ]] && return 130

      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if (( idx >= 0 && idx < ${#actions[@]} )); then
          action="${actions[$idx]}"
          break
        fi
        echo "Invalid number."
      else
        echo "Enter a number."
      fi
    done
  fi

  # --- Dispatch ---
  case "$action" in
    start)
      echo "Starting ${chosen_name}..."
      docker start "$chosen_name"
      return $?
      ;;
    stop)
      echo "Stopping ${chosen_name}..."
      docker stop "$chosen_name"
      return $?
      ;;
    enter)
      # Re-verify still running before exec
      local current_state
      current_state="$(__docker_container_state "$chosen_name")"
      if [[ "$current_state" != "running" ]]; then
        echo "doctrl: '${chosen_name}' is no longer running (state: ${current_state})" >&2
        return 1
      fi
      # Prefer bash; fall back to sh
      if docker exec "$chosen_name" which bash >/dev/null 2>&1; then
        docker exec -it  --user dev -w /var/www/html "$chosen_name" bash
      else
        docker exec -it  --user dev -w /var/www/html "$chosen_name" sh
      fi
      return $?
      ;;
    *)
      echo "doctrl: unknown action '${action}'" >&2
      return 1
      ;;
  esac
}

# --- end docker wrapper ---

# Source this file from your ~/.bashrc or ~/.bash_profile:
#
#   [ -f /path/to/docker.sh ] && . /path/to/docker.sh
#
# Requires: docker
# Optional: fzf (for interactive menus)
#   sudo apt-get install fzf
