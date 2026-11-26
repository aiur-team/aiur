# Bash sources BASH_ENV after login profiles. Restore the workspace command
# guards here because profiles such as Debian's can replace PATH during startup.
if [[ -n ${AIUR_AGENT_BIN:-} ]]; then
  PATH="$AIUR_AGENT_BIN:$PATH"
  export PATH
fi

# Keep the build admission hook alongside the PATH repair without trusting the
# operator's BASH_ENV value.
if [[ -n ${AIUR_BUILD_GATE_HOOK:-} && -r ${AIUR_BUILD_GATE_HOOK} ]]; then
  source "$AIUR_BUILD_GATE_HOOK"
fi
