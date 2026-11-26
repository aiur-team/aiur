# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
command_name=
subcommand_name=
# The third positional word, where `gh pr view 2073` and its siblings put the
# resource number. The shared-state cache reads the identity from exactly this
# position and nowhere else, so a rarer spelling such as
# `gh pr view --json body 2073` resolves to no identity and is simply not
# cached. Guessing a position instead would risk keying a response under the
# wrong number, and a wrong cached shape is worse than a cache miss.
positional_three=
positional_count=0
skip_root_value=0
for arg in "$@"; do
  if [ "$skip_root_value" -eq 1 ]; then
    skip_root_value=0
    continue
  fi
  case "$arg" in
    -R|--repo|--hostname) skip_root_value=1; continue ;;
    -R?*|--repo=*|--hostname=*) continue ;;
  esac
  positional_count=$((positional_count + 1))
  case "$positional_count" in
    1) command_name=$arg ;;
    2) subcommand_name=$arg ;;
    *) positional_three=$arg; break ;;
  esac
done
unset positional_count
command_key="$command_name $subcommand_name"

