#!/usr/bin/env bash

set -euo pipefail

mode="${1:-}"
pane_path="${2:-}"
pane_ref="${3:-}"

read_pane_env() {
  local pid="${1:-}"
  if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ"
  fi
}

git_branch() {
  local path="${1:-}"
  [ -n "$path" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local branch
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    branch="$(git -C "$path" describe --tags --exact-match 2>/dev/null || git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"
  fi

  [ -n "$branch" ] && printf '%s' "$branch"
}

runtime_env() {
  local env_lines py_env node_env go_env
  env_lines="$(read_pane_env "$1")"

  py_env="$(
    printf '%s\n' "$env_lines" | awk -F= '
      $1 == "CONDA_DEFAULT_ENV" { print "py:" $2; exit }
      $1 == "VIRTUAL_ENV" {
        n = split($2, parts, "/")
        print "py:" parts[n]
        exit
      }'
  )"

  node_env="$(
    printf '%s\n' "$env_lines" | awk -F= '
      $1 == "NVM_BIN" {
        n = split($2, parts, "/")
        for (i = 1; i <= n; i++) {
          if (parts[i] ~ /^v[0-9]/) {
            print "node:" parts[i]
            exit
          }
        }
      }
      $1 == "FNM_VERSION_FILE_STRATEGY" { fnm = 1 }
      $1 == "VOLTA_HOME" { volta = 1 }
      END {
        if (fnm) print "node:fnm"
        else if (volta) print "node:volta"
      }'
  )"

  go_env="$(
    printf '%s\n' "$env_lines" | awk -F= '
      $1 == "GOTOOLCHAIN" && $2 != "auto" { print "go:" $2; exit }
      $1 == "GOVERSION" { print "go:" $2; exit }'
  )"

  printf '%s %s %s' "$py_env" "$node_env" "$go_env" | xargs
}

ssh_state() {
  local tty="${1:-}"
  local pid="${2:-}"

  if [ -n "$tty" ] && ps -t "$tty" -o comm= 2>/dev/null | grep -Eq '^(ssh|mosh|mosh-client)$'; then
    printf 'ssh'
    return 0
  fi

  local env_lines
  env_lines="$(read_pane_env "$pid")"
  if printf '%s\n' "$env_lines" | grep -q '^SSH_CONNECTION='; then
    printf 'ssh'
  else
    printf 'local'
  fi
}

system_stats() {
  [ -r /proc/loadavg ] || return 0

  local load cpu_line idle total usage
  load="$(awk '{printf "load:%s %s %s", $1, $2, $3}' /proc/loadavg)"

  if [ -r /proc/stat ]; then
    cpu_line="$(awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9}' /proc/stat)"
    local user nice system idle_v iowait irq softirq steal
    read -r user nice system idle_v iowait irq softirq steal <<< "$cpu_line"
    idle=$((idle_v + iowait))
    total=$((user + nice + system + idle_v + iowait + irq + softirq + steal))

    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux"
    local cache_file="$cache_dir/cpu.stat"
    mkdir -p "$cache_dir"

    if [ -r "$cache_file" ]; then
      local prev_total prev_idle delta_total delta_idle
      read -r prev_total prev_idle < "$cache_file" || true
      delta_total=$((total - prev_total))
      delta_idle=$((idle - prev_idle))
      if [ "$delta_total" -gt 0 ]; then
        usage=$(( (100 * (delta_total - delta_idle)) / delta_total ))
      else
        usage=0
      fi
    else
      usage=0
    fi

    printf '%s %s\n' "$total" "$idle" > "$cache_file"
  else
    usage=0
  fi

  local mem=""
  if command -v free >/dev/null 2>&1; then
    mem="$(free -m | awk '/^Mem:/ {printf "mem:%d/%dM", $3, $2}')"
  fi

  printf 'cpu:%s%% %s %s' "$usage" "$mem" "$load" | xargs
}

case "$mode" in
  git)
    git_branch "$pane_path"
    ;;
  env)
    runtime_env "$pane_ref"
    ;;
  ssh)
    ssh_state "$pane_path" "$pane_ref"
    ;;
  sys)
    system_stats
    ;;
esac
