#!/bin/sh
# Caller environment tokens must not leak to the deadline supervisor or helpers.
unset GH_TOKEN GITHUB_TOKEN guard_token budget_token
: "${AIUR_GITHUB_BUDGET_ROOT:=$HOME/.aiur/github-budget}"
: "${AIUR_GITHUB_BUDGET_BROKER:=$(dirname "$0")/gh-access-broker}"
: "${AIUR_GITHUB_BUDGET_CONSUMER:=gh-access}"
export AIUR_GITHUB_BUDGET_ROOT AIUR_GITHUB_BUDGET_BROKER AIUR_GITHUB_BUDGET_CONSUMER
