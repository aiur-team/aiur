# Dotenv loading and the GitHub credential group precedence. Sourced by aiur-engine.sh.

# file only fills names that are still unset, so the repo-local file (the more
# specific scope) is read first and the machine-wide file only fills its gaps.
# A blank value is a placeholder, not a setting: `aiur init` scaffolds
# `GITHUB_TOKEN=` and `.env.example` renders every name blank, so a blank line
# neither exports nor shadows anything.
#
# GitHub credentials are one group. A repo `.env` that sets any member has
# chosen that repository's auth mode, so none of the global file's members may
# leak in beside it: a global GITHUB_APP_* triple filling the gaps around a
# repo-local GITHUB_TOKEN would outrank that token and force the daemon onto an
# App that is not installed on the repo (#2638).
GITHUB_CREDENTIAL_ENV_NAMES="GITHUB_TOKEN GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH GITHUB_APP_PRIVATE_KEY"

load_dotenv() {
  local global_skip=""
  if dotenv_file_sets_github_credential ".env"; then
    global_skip="github_credentials"
  fi
  load_dotenv_file ".env"
  load_dotenv_file "$HOME/.aiur/.env" "$global_skip"
}

github_credential_env_name() {
  case " $GITHUB_CREDENTIAL_ENV_NAMES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Parses one dotenv line into DOTENV_KEY / DOTENV_VAL. Returns 1 for blank,
# comment, malformed, and blank-valued lines so callers skip them. Shared by
# the loader and the credential-group probe so both agree on what counts.
parse_dotenv_line() {
  local line="$1" key val
  DOTENV_KEY="" DOTENV_VAL=""
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in '' | '#'*) return 1 ;; esac
  [ "${line#*=}" = "$line" ] && return 1
  key="${line%%=*}"
  key="${key%"${key##*[![:space:]]}"}"
  case "$key" in '' | *[!A-Za-z0-9_]*) return 1 ;; esac
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  case "$val" in
    \"*\") val="${val#\"}" && val="${val%\"}" ;;
    \'*\') val="${val#\'}" && val="${val%\'}" ;;
  esac
  [ -n "$val" ] || return 1
  DOTENV_KEY="$key"
  DOTENV_VAL="$val"
}

# True when the file sets any GitHub credential name to a non-blank value.
dotenv_file_sets_github_credential() {
  local file="$1" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    parse_dotenv_line "$line" || continue
    if github_credential_env_name "$DOTENV_KEY"; then
      return 0
    fi
  done <"$file"
  return 1
}

# Usage: load_dotenv_file <file> [github_credentials]
# The optional second argument skips the GitHub credential group.
load_dotenv_file() {
  local file="$1" skip="${2:-}" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    parse_dotenv_line "$line" || continue
    if [ "$skip" = "github_credentials" ] && github_credential_env_name "$DOTENV_KEY"; then
      continue
    fi
    [ -n "${!DOTENV_KEY+x}" ] && continue
    export "$DOTENV_KEY=$DOTENV_VAL"
  done <"$file"
}

# The readiness token grants the one-shot `aiur init` assessment access that a
# normal daemon and its child agents must never inherit. Keep dotenv loading
# generic, then remove this run-only secret before any session process starts.
scrub_run_only_env() {
  unset AIUR_CI_READINESS_TOKEN
}
