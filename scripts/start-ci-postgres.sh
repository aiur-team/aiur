#!/usr/bin/env bash
set -euo pipefail

container=aiur-ticket-lease-postgres
docker run --detach --name "$container" --publish 5432:5432 \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD=postgres \
  --env POSTGRES_DB=aiur_test \
  --health-cmd 'pg_isready -U postgres -d aiur_test' \
  --health-interval 2s --health-timeout 5s --health-retries 30 \
  postgres:16

for _ in {1..60}; do
  health=$(docker inspect --format '{{.State.Health.Status}}' "$container")
  case "$health" in
    healthy) exit 0 ;;
    unhealthy)
      docker logs "$container"
      exit 1
      ;;
  esac
  sleep 1
done

docker logs "$container"
echo "PostgreSQL did not become healthy within 60 seconds" >&2
exit 1
