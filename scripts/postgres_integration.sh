#!/usr/bin/env bash
set -euo pipefail
container_name="neuron-postgres-test-$$"
port="${NEURON_POSTGRES_PORT:-15432}"
cleanup() { podman rm --force "$container_name" >/dev/null; }
trap cleanup EXIT
podman run --detach --name "$container_name" \
  --publish "127.0.0.1:${port}:5432" \
  --env POSTGRES_PASSWORD=neuron_test --env POSTGRES_DB=neuron_test \
  docker.io/library/postgres:17 >/dev/null
for _ in $(seq 1 60); do
  if podman exec "$container_name" pg_isready --username postgres --dbname neuron_test >/dev/null; then
    break
  fi
  sleep 1
done
podman exec "$container_name" pg_isready --username postgres --dbname neuron_test
NEURON_TEST_POSTGRES_URL="postgres://postgres:neuron_test@localhost:${port}/neuron_test" mix test
