#!/usr/bin/env bash
# Manage the Docker-less PostgreSQL cluster used in Amp orbs. Workstation
# development uses docker-compose.yml, but both paths expose the same socket.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pgdata="$repo_root/dev/postgres"
log_file="$repo_root/dev/postgres.log"
socket_dir="$repo_root/tmp/postgres-socket"

write_config() {
  local conf="$pgdata/postgresql.conf"
  local include_line="include = 'renga.conf'"

  if ! grep -qx "$include_line" "$conf"; then
    printf '\n# Local socket-only settings; see scripts/local-postgres.sh.\n%s\n' "$include_line" >>"$conf"
  fi

  cat >"$pgdata/renga.conf" <<CONFIG
# Managed by scripts/local-postgres.sh. Change that script, not this file.
listen_addresses = ''
unix_socket_directories = '$socket_dir'
unix_socket_permissions = 0700

# This names the socket file; listen_addresses disables the TCP listener.
port = 5432
CONFIG
}

init_cluster() {
  if [ -f "$pgdata/PG_VERSION" ]; then
    local postgres_major
    postgres_major="$(postgres --version | awk '{print $3}' | cut -d. -f1)"

    if [ "$(cat "$pgdata/PG_VERSION")" != "$postgres_major" ]; then
      echo "PostgreSQL data directory uses a different major version; remove dev/postgres and rerun." >&2
      exit 1
    fi

    return
  fi

  if [ -e "$pgdata" ]; then
    echo "PostgreSQL data directory is incomplete; remove dev/postgres and rerun." >&2
    exit 1
  fi

  local staging="$pgdata.initializing"
  rm -rf "$staging"
  mkdir -p "$(dirname "$pgdata")"
  initdb --auth-local=trust --auth-host=trust --encoding=UTF8 --username=postgres --pgdata="$staging" >/dev/null
  mv "$staging" "$pgdata"
}

running() {
  [ -f "$pgdata/PG_VERSION" ] && pg_ctl --pgdata="$pgdata" status >/dev/null 2>&1
}

case "${1:-start}" in
start)
  init_cluster

  # Restart clusters created by the old TCP configuration so the managed
  # socket-only settings take effect without replacing their data.
  if running && ! pg_isready --host="$socket_dir" --quiet; then
    pg_ctl --pgdata="$pgdata" --wait --timeout=5 stop >/dev/null
  fi

  if ! running; then
    write_config
    mkdir -p "$socket_dir"
    pg_ctl --pgdata="$pgdata" --log="$log_file" --wait --timeout=5 start >/dev/null
  fi

  pg_isready --host="$socket_dir" --quiet
  echo "PostgreSQL is listening on $socket_dir/.s.PGSQL.5432"
  ;;
stop)
  if running; then
    pg_ctl --pgdata="$pgdata" --wait --timeout=5 stop >/dev/null
  fi
  ;;
status)
  if ! running; then
    echo "PostgreSQL is not running" >&2
    exit 1
  fi

  pg_ctl --pgdata="$pgdata" status
  ;;
psql)
  shift
  exec psql --host="$socket_dir" --username=postgres --dbname=renga_dev "$@"
  ;;
*)
  echo "usage: scripts/local-postgres.sh <start|stop|status|psql> [psql args...]" >&2
  exit 64
  ;;
esac
