#!/usr/bin/env bash
set -euo pipefail

container_name="${NEURON_DGRAPH_CONTAINER:-neuron-dgraph-test-$$}"
image="${NEURON_DGRAPH_IMAGE:-docker.io/dgraph/standalone:v25.4.0}"

cleanup() {
  podman rm --force "$container_name" >/dev/null 2>&1 || true
}

trap cleanup EXIT

podman run --detach \
  --name "$container_name" \
  --publish "${NEURON_DGRAPH_HTTP_PORT:-18080}:8080" \
  --publish "${NEURON_DGRAPH_GRPC_PORT:-19080}:9080" \
  "$image" >/dev/null

health_url="http://localhost:${NEURON_DGRAPH_HTTP_PORT:-18080}/health"
for _ in $(seq 1 60); do
  if curl --fail --silent "$health_url" >/dev/null; then
    break
  fi

  sleep 1
done

if ! curl --fail --silent "$health_url" >/dev/null; then
  echo "Dgraph did not become healthy at $health_url" >&2
  exit 1
fi

NEURON_DGRAPH_ENABLED=true \
NEURON_DGRAPH_ENDPOINT="localhost:${NEURON_DGRAPH_GRPC_PORT:-19080}" \
NEURON_DGRAPH_TRANSPORT=grpc \
  mix test --include integration test/neuron_dgraph_integration_test.exs test/neuron_campaign_pipeline_integration_test.exs test/neuron_intake_excerpt_test.exs test/neuron_intake_answers_test.exs test/neuron_leadership_people_test.exs test/neuron_people_pages_test.exs
