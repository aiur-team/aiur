#!/usr/bin/env bash
set -euo pipefail

attempt="${1:?usage: report-ci-run-attempt.sh <run-attempt> <summary-path>}"
summary_path="${2:?usage: report-ci-run-attempt.sh <run-attempt> <summary-path>}"

if [[ ! "$attempt" =~ ^[1-9][0-9]*$ ]]; then
  echo "run attempt must be a positive integer: $attempt" >&2
  exit 1
fi

if ((attempt > 1)); then
  printf '> CI rerun: attempt %s of this workflow run.\n' "$attempt" >>"$summary_path"
fi
