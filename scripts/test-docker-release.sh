#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
run_id="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}"
run_id="${run_id//[^a-zA-Z0-9_.-]/-}"
image="renga-release-test:${run_id}"
publish_as="${1:-}"
postgres_image="renga-postgres-test:${run_id}"
network="renga-release-test-${run_id}"
app_container="renga-app-test-${run_id}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/renga-release-test.XXXXXX")"
containers=()

cleanup() {
  docker rm -fv "$app_container" "${containers[@]}" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$postgres_image" "$image" >/dev/null 2>&1 || true
  rm -rf "$temp_dir"
}
trap cleanup EXIT

make_ca() {
  local name=$1

  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj "/CN=${name}" \
    -keyout "$temp_dir/${name}.key" \
    -out "$temp_dir/${name}.crt" >/dev/null 2>&1
}

make_server_cert() {
  local name=$1
  local hostname=$2
  local ca=$3
  local serial=$4

  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=${hostname}" \
    -keyout "$temp_dir/${name}.key" \
    -out "$temp_dir/${name}.csr" >/dev/null 2>&1

  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$hostname" >"$temp_dir/${name}.ext"
  openssl x509 -req -sha256 -days 1 \
    -in "$temp_dir/${name}.csr" \
    -CA "$temp_dir/${ca}.crt" \
    -CAkey "$temp_dir/${ca}.key" \
    -set_serial "$serial" \
    -extfile "$temp_dir/${name}.ext" \
    -out "$temp_dir/${name}.crt" >/dev/null 2>&1
}

start_postgres() {
  local name=$1
  local hostname=$2
  local certificate=${3:-}
  local container="renga-${name}-test-${run_id}"
  local args=()

  if [[ -n "$certificate" ]]; then
    args=(
      -c ssl=on
      -c "ssl_cert_file=/certs/${certificate}.crt"
      -c "ssl_key_file=/certs/${certificate}.key"
    )
  fi

  docker run --detach --name "$container" \
    --network "$network" --network-alias "$hostname" \
    --env POSTGRES_USER=renga \
    --env POSTGRES_PASSWORD=renga \
    --env POSTGRES_DB=renga \
    "$postgres_image" "${args[@]}" >/dev/null
  containers+=("$container")

  for _attempt in {1..60}; do
    if docker exec "$container" pg_isready --username renga --dbname renga >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  docker logs "$container"
  printf 'PostgreSQL container %s did not become ready\n' "$container" >&2
  return 1
}

release_env() {
  local database_host=$1
  shift
  local command=(
    docker run --rm --network "$network"
    --mount "$test_ca_mount"
    --env "DATABASE_URL=ecto://renga:renga@${database_host}:5432/renga"
    --env DATABASE_SSL=true
    --env PHX_HOST=renga.example.com
    --env SECRET_KEY_BASE=rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
    "$image_id" "$@"
  )

  if [[ -n "${RELEASE_TIMEOUT:-}" ]]; then
    timeout "$RELEASE_TIMEOUT" "${command[@]}"
  else
    "${command[@]}"
  fi
}

expect_tls_failure() {
  local label=$1
  local database_host=$2
  local expected_error=$3
  local log="$temp_dir/${label}.log"
  local status

  set +e
  RELEASE_TIMEOUT=45s release_env "$database_host" /app/bin/migrate >"$log" 2>&1
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    printf 'Expected %s database connection to fail\n' "$label" >&2
    cat "$log" >&2
    return 1
  fi

  if [[ "$status" -ne 1 ]]; then
    printf '%s database connection exited with unexpected status %s\n' "$label" "$status" >&2
    cat "$log" >&2
    return 1
  fi

  if ! grep -Eqi "$expected_error" "$log"; then
    printf '%s database connection did not report the expected TLS error\n' "$label" >&2
    cat "$log" >&2
    return 1
  fi

  printf 'Verified rejection: %s\n' "$label"
}

make_ca trusted-ca
make_ca untrusted-ca
# OTP reads this Debian trust bundle; mount only the test root without changing
# the image's filesystem layers, default user, or command.
chmod 0644 "$temp_dir/trusted-ca.crt"
test_ca_mount="type=bind,source=$temp_dir/trusted-ca.crt,target=/etc/ssl/certs/ca-certificates.crt,readonly"
make_server_cert trusted postgres trusted-ca 1
make_server_cert wrong wrong.example trusted-ca 2
make_server_cert untrusted postgres-untrusted untrusted-ca 1

cat >"$temp_dir/Postgres.Dockerfile" <<'EOF'
FROM postgres:17-alpine
COPY --chown=postgres:postgres trusted.crt trusted.key wrong.crt wrong.key untrusted.crt untrusted.key /certs/
RUN chmod 600 /certs/*.key
EOF

build_args=()
if [[ -n "$publish_as" ]]; then
  build_args+=(--label "org.opencontainers.image.source=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}")
fi
docker build "${build_args[@]}" --tag "$image" "$repo_root"
image_id=$(docker image inspect --format '{{.Id}}' "$image")
release_uid=$(docker run --rm --entrypoint id "$image_id" -u)
test "$release_uid" -ne 0
docker build --tag "$postgres_image" --file "$temp_dir/Postgres.Dockerfile" "$temp_dir"
docker network create "$network" >/dev/null

start_postgres trusted-db postgres trusted
start_postgres wrong-host-db postgres-wrong wrong
start_postgres untrusted-db postgres-untrusted untrusted
start_postgres plaintext-db postgres-plaintext

# The release migration command must migrate a new database and be idempotent.
release_env postgres /app/bin/migrate
release_env postgres /app/bin/migrate

# The image's default command must serve both the application and its digested assets.
docker run --detach --name "$app_container" \
  --network "$network" --publish 127.0.0.1::4000 \
  --mount "$test_ca_mount" \
  --env DATABASE_URL=ecto://renga:renga@postgres:5432/renga \
  --env DATABASE_SSL=true \
  --env PHX_HOST=renga.example.com \
  --env SECRET_KEY_BASE=rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr \
  "$image_id" >/dev/null

host_port="$(docker port "$app_container" 4000/tcp | sed -n '1s/.*://p')"
for _attempt in {1..60}; do
  if curl --fail --silent --show-error \
    "http://127.0.0.1:${host_port}/users/log-in" >"$temp_dir/login.html"; then
    break
  fi
  sleep 1
done

if [[ ! -s "$temp_dir/login.html" ]]; then
  docker logs "$app_container"
  printf 'Renga server did not become ready\n' >&2
  exit 1
fi

stylesheet="$(grep -oE 'href="[^"]+\.css[^"]*"' "$temp_dir/login.html" | head -1 | cut -d '"' -f2)"
javascript="$(grep -oE 'src="[^"]+\.js[^"]*"' "$temp_dir/login.html" | head -1 | cut -d '"' -f2)"
test -n "$stylesheet"
test -n "$javascript"
curl --fail --silent --show-error "http://127.0.0.1:${host_port}${stylesheet}" >/dev/null
curl --fail --silent --show-error "http://127.0.0.1:${host_port}${javascript}" >/dev/null

tls_connections="$({
  docker exec "renga-trusted-db-test-${run_id}" \
    psql --username renga --dbname renga --tuples-only --no-align \
    --command "SELECT count(*) > 0 AND bool_and(s.ssl) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.usename = 'renga' AND a.pid <> pg_backend_pid();"
} | tr -d '[:space:]')"
test "$tls_connections" = t

expect_tls_failure untrusted-ca postgres-untrusted 'unknown_ca|unknown ca'
expect_tls_failure wrong-hostname postgres-wrong 'hostname_check_failed|hostname check failed'
expect_tls_failure plaintext postgres-plaintext 'ssl not available'

# Keep a second reference only after the base image passes all smoke checks.
if [[ -n "$publish_as" ]]; then
  docker tag "$image_id" "$publish_as"
fi

printf 'Docker release smoke test passed\n'
