#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/action-plan.sh"

test_count=0

check() {
  local description="$1"
  shift
  test_count=$((test_count + 1))
  if "$@"; then
    printf 'ok %d - %s\n' "$test_count" "$description"
  else
    printf 'not ok %d - %s\n' "$test_count" "$description" >&2
    exit 1
  fi
}

array_contains() {
  local expected="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$expected" ]] && return 0
  done
  return 1
}

array_not_contains() {
  ! array_contains "$@"
}

command_fails() {
  ! "$@"
}

injection_sentinel="${TMPDIR:-/tmp}/taffish-index-action-plan-$$"
trap 'rm -f "$injection_sentinel"' EXIT

taffish_index_action_plan_args
unset_args="$(printf '%q ' "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}")"
check "schedule/unset mode has no retry flag" \
  array_not_contains --retry-failed "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"
check "schedule/unset mode has no backfill flag" \
  array_not_contains --backfill "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"

taffish_index_action_plan_args "" false
false_args="$(printf '%q ' "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}")"
check "manual false mode matches schedule/unset arguments" \
  test "$false_args" = "$unset_args"

taffish_index_action_plan_args "" true
check "manual retry mode emits one retry flag" \
  array_contains --retry-failed "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"
check "manual retry mode does not emit backfill" \
  array_not_contains --backfill "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"

taffish_index_action_plan_args 10 false
check "bounded backfill emits the backfill flag" \
  array_contains --backfill "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"
check "bounded backfill preserves its numeric value" \
  array_contains 10 "${TAFFISH_INDEX_ACTION_PLAN_ARGS[@]}"

check "retry and backfill are rejected together" \
  command_fails taffish_index_action_plan_args 10 true

for invalid_limit in 0 51 -1 1.5 " " "1; touch $injection_sentinel"; do
  check "invalid backfill input is rejected: $invalid_limit" \
    command_fails taffish_index_action_plan_args "$invalid_limit" false
done

for invalid_retry in TRUE yes 1 " " "true; touch $injection_sentinel"; do
  check "invalid retry input is rejected: $invalid_retry" \
    command_fails taffish_index_action_plan_args "" "$invalid_retry"
done

check "malicious input is never executed" \
  test ! -e "$injection_sentinel"

printf '1..%d\n' "$test_count"
printf 'All %d Action plan argument tests passed.\n' "$test_count"
