#!/usr/bin/env bash

set -euo pipefail

taffish_index_action_plan_args() {
  local backfill_limit="${1-}"
  local retry_failed="${2-false}"

  TAFFISH_INDEX_ACTION_PLAN_ARGS=(
    --org taffish
    --index-dir index
    --output work/plan.json
    --jobs 8
    --backends docker,podman,apptainer
    --policy-generation multibackend-1
    --platform linux/amd64
  )

  if [[ -n "$backfill_limit" ]]; then
    if [[ ! "$backfill_limit" =~ ^([1-9]|[1-4][0-9]|50)$ ]]; then
      echo "backfill_limit must be blank or an integer from 1 to 50" >&2
      return 1
    fi
    TAFFISH_INDEX_ACTION_PLAN_ARGS+=(
      --backfill --backfill-limit "$backfill_limit"
    )
  fi

  case "$retry_failed" in
    true)
      if [[ -n "$backfill_limit" ]]; then
        echo "retry_failed cannot be combined with backfill_limit" >&2
        return 1
      fi
      TAFFISH_INDEX_ACTION_PLAN_ARGS+=(--retry-failed)
      ;;
    false)
      ;;
    *)
      echo "retry_failed must be true or false" >&2
      return 1
      ;;
  esac
}

taffish_index_run_action_plan() {
  taffish_index_action_plan_args "${BACKFILL_LIMIT_INPUT-}" \
    "${RETRY_FAILED_INPUT-false}"
  mkdir -p work
  sbcl --script scripts/index-phase.lisp plan \
    "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  taffish_index_run_action_plan
fi
