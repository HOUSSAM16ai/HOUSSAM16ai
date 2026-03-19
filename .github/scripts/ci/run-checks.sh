#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

log() {
  printf '\n[%s] %s\n' "$1" "$2"
}

run_cmd() {
  log RUN "$*"
  "$@"
}

has_file() {
  compgen -G "$1" >/dev/null 2>&1
}

has_npm_script() {
  local script_name="$1"
  [ -f package.json ] || return 1
  node -e "const fs=require('fs');const pkg=JSON.parse(fs.readFileSync('package.json','utf8'));process.exit(pkg.scripts && pkg.scripts['${script_name}'] ? 0 : 1);"
}

validate_workflows() {
  if ! [ -d .github/workflows ]; then
    log INFO "No workflow directory found; skipping workflow validation"
    return 0
  fi

  while IFS= read -r workflow_file; do
    log INFO "Validating workflow YAML: ${workflow_file}"
    run_cmd ruby -e "require 'yaml'; YAML.load_file(ARGV.fetch(0))" "$workflow_file"
  done < <(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
}

validate_shell_scripts() {
  if ! [ -d .github/scripts ]; then
    log INFO "No GitHub shell scripts found; skipping shell validation"
    return 0
  fi

  while IFS= read -r script_file; do
    log INFO "Linting shell syntax: ${script_file}"
    run_cmd bash -n "$script_file"
  done < <(find .github/scripts -type f -name '*.sh' | sort)
}

baseline_checks() {
  log INFO "Running baseline repository checks"
  run_cmd git diff --check
  validate_workflows
  validate_shell_scripts
}

node_package_manager() {
  if [ -f pnpm-lock.yaml ]; then
    printf 'pnpm'
  elif [ -f yarn.lock ]; then
    printf 'yarn'
  elif [ -f package-lock.json ]; then
    printf 'npm'
  else
    printf 'unknown'
  fi
}

install_node_dependencies() {
  local package_manager="$1"

  case "$package_manager" in
    pnpm)
      run_cmd corepack enable
      run_cmd pnpm install --frozen-lockfile
      ;;
    yarn)
      run_cmd corepack enable
      run_cmd yarn install --immutable
      ;;
    npm)
      run_cmd npm ci
      ;;
    *)
      log SKIP "Skipping Node.js CI because no supported lockfile was found"
      return 1
      ;;
  esac
}

run_project_ci() {
  if [ -x ./scripts/ci.sh ]; then
    log INFO "Running repository CI entrypoint: ./scripts/ci.sh"
    run_cmd ./scripts/ci.sh
    return 0
  fi

  if [ -f Makefile ] && grep -Eq '(^|[[:space:]])ci:' Makefile; then
    log INFO "Running repository CI entrypoint: make ci"
    run_cmd make ci
    return 0
  fi

  if [ -f package.json ] && has_npm_script ci; then
    local package_manager
    package_manager="$(node_package_manager)"

    if install_node_dependencies "$package_manager"; then
      case "$package_manager" in
        pnpm)
          run_cmd pnpm ci
          ;;
        yarn)
          run_cmd yarn ci
          ;;
        npm)
          run_cmd npm run ci
          ;;
      esac
    fi

    return 0
  fi

  log INFO "No explicit project CI entrypoint detected; baseline checks are sufficient"
}

main() {
  baseline_checks
  run_project_ci
  log DONE "Repository quality gate completed successfully"
}

main "$@"
