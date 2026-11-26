# Read-only transcript commands. Validate every value before constructing RPC code.
# @cli-reference aiur voice transcripts [<conversation_id>] [--target <ticket>|executor] [--limit N] [--json] | List voice sessions or show a complete transcript in file order. | aiur voice transcripts --target executor --json
cmd_voice() {
  [ "${1:-}" = transcripts ] || { echo 'aiur: expected voice transcripts' >&2; exit 64; }
  shift
  local arg id="" target="" limit="" target_set=false limit_set=false json=false args=""
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --target|--limit)
        [ "$#" -gt 1 ] || { echo "aiur: $arg requires a value" >&2; exit 64; }
        shift
        if [ "$arg" = --target ]; then target="$1"; target_set=true; else limit="$1"; limit_set=true; fi ;;
      --target=*) target="${arg#--target=}"; target_set=true ;;
      --limit=*) limit="${arg#--limit=}"; limit_set=true ;;
      --json) json=true ;;
      -*) echo "aiur: unknown voice option: $arg" >&2; exit 64 ;;
      *) [ -n "$arg" ] || { echo 'aiur: invalid conversation id' >&2; exit 64; }; [ -z "$id" ] || { echo 'aiur: expected one conversation id' >&2; exit 64; }; id="$arg" ;;
    esac
    shift
  done
  if [ -n "$id" ] && ! [[ "$id" =~ ^vc_[A-Za-z0-9_-]{22}$ ]]; then
    echo 'aiur: invalid conversation id' >&2; exit 64
  fi
  if [ "$target_set" = true ] && ! [[ "$target" =~ ^[A-Za-z0-9#/_.-]{1,80}$ ]]; then
    echo 'aiur: invalid transcript target' >&2; exit 64
  fi
  if [ "$limit_set" = true ] && ! [[ "$limit" =~ ^([1-9]|[1-9][0-9]|100)$ ]]; then
    echo 'aiur: transcript limit must be 1..100' >&2; exit 64
  fi
  if [ -n "$id" ] && { [ -n "$target" ] || [ -n "$limit" ]; }; then
    echo 'aiur: --target and --limit apply only to listing' >&2; exit 64
  fi
  [ -z "$id" ] || args="\"$id\", "
  [ -z "$target" ] || args="$args\"--target\", \"$target\", "
  [ -z "$limit" ] || args="$args\"--limit\", \"$limit\", "
  [ "$json" = false ] || args="$args\"--json\", "
  run_control_rpc "Aiur.VoiceCLI.transcripts([${args%, }])"
}
