# Shared launcher epic command parser. Sourced by aiur-engine.sh.
# `aiur epic show|list` read the lane overrides until epic records replace them.
# The write verbs are the deprecated spelling of `aiur lane`, so they print the
# deprecation line on stderr and parse through the lane command.
cmd_epic() {
  case "${1:-}" in
    set|clear|confirm) echo 'aiur: epic '"${1}"' is deprecated; use aiur lane '"${1}" >&2 ;;
  esac
  cmd_lane "$@"
}
