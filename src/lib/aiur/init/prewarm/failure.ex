defmodule Aiur.Init.Prewarm.Failure do
  @moduledoc """
  Warm-base build failure reporting for `aiur init`.

  This module classifies clone/auth/build failures, prints class-specific
  Executor guidance, and emits the ready-to-paste handoff prompt with captured
  failure output embedded.
  """

  alias Aiur.Init.Format

  # A warm-base build that fails at runtime (private-repo clone auth, network, or
  # a broken base_build command) used to print a single "retries next run" line
  # with no path forward. Classify the failure, give the Executor concrete
  # self-resolution steps for that class, and hand them a ready-to-paste prompt —
  # embedding the actual captured failure output — so a coding agent can fix it.
  @doc false
  @spec report(Aiur.Init.io(), String.t(), String.t(), term()) :: :ok
  def report(io, repo, cmd, reason) do
    class = classify_prewarm_failure(reason)

    io.puts.(["\n⚠️  Warm base build failed (", inspect(reason), ")."])
    io.puts.(prewarm_failure_guidance(class, repo))

    io.puts.([
      "\nOr paste this to your coding agent to fix it for you:\n\n",
      Format.dim(prewarm_failure_prompt(repo, cmd, reason))
    ])

    io.puts.("\nThe warm base also retries automatically on the next `aiur` run.")
  end

  # Clone/fetch/reset failures carry the git stderr; an auth signature in it means
  # the token is missing/invalid/unauthorized. A base_build failure is a toolchain
  # problem. Anything else degrades to generic guidance.
  @doc false
  @spec classify_prewarm_failure(term()) :: :auth | :clone | :build | :other
  def classify_prewarm_failure({tag, _status, out})
      when tag in [:repo_base_clone_failed, :repo_base_fetch_failed, :repo_base_reset_failed] and
             is_binary(out) do
    if auth_error?(out), do: :auth, else: :clone
  end

  def classify_prewarm_failure({:base_build_failed, _status, _out}), do: :build
  def classify_prewarm_failure(_reason), do: :other

  @doc false
  @spec auth_error?(String.t()) :: boolean()
  def auth_error?(out) do
    out = String.downcase(out)

    Enum.any?(
      [
        "authentication failed",
        "could not read username",
        "invalid username or token",
        "password authentication",
        "terminal prompts disabled",
        "permission denied",
        "403 forbidden"
      ],
      &String.contains?(out, &1)
    )
  end

  @doc false
  @spec prewarm_failure_guidance(:auth | :clone | :build | :other, String.t()) :: iodata()
  def prewarm_failure_guidance(:auth, repo) do
    [
      "\nThis looks like a GitHub authentication failure cloning ",
      Format.dim(repo),
      ".\nTo fix it yourself:\n",
      "  • Make sure GITHUB_TOKEN is set in .env and still valid:\n",
      "      ",
      Format.dim(~s(curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user)),
      "\n",
      "  • The token's account must have read access to this repo.\n",
      "  • Classic tokens need the `repo` scope; fine-grained tokens need Contents: Read.\n",
      "  • Then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  def prewarm_failure_guidance(:clone, repo) do
    [
      "\nThe warm-base clone of ",
      Format.dim(repo),
      " failed.\nTo fix it yourself:\n",
      "  • Confirm the repo exists and is reachable from this machine.\n",
      "  • Check your network/proxy, and that GITHUB_TOKEN (if the repo is private) has access.\n",
      "  • Then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  def prewarm_failure_guidance(:build, _repo) do
    [
      "\nThe repo cloned, but the base_build command failed.\nTo fix it yourself:\n",
      "  • Run the base_build command in a clean checkout and watch where it breaks.\n",
      "  • Fix it in .aiur/config under prewarm.base_build (keep it idempotent).\n",
      "  • Then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  def prewarm_failure_guidance(:other, _repo) do
    [
      "\nTo fix it yourself, inspect the error above, resolve the underlying cause,\n",
      "then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  # The AI handoff, mirroring `prewarm_fallback_prompt/0` but for a *runtime*
  # failure: it embeds the repo, the configured base_build, and the captured
  # failure output so the agent can diagnose auth vs. toolchain without guessing.
  @doc false
  @spec prewarm_failure_prompt(String.t(), String.t(), term()) :: String.t()
  def prewarm_failure_prompt(repo, cmd, reason) do
    """
    You are working in a repository managed by aiur, an agent-orchestration
    runtime. To avoid every agent cold-cloning and recompiling, aiur keeps one
    shared, pre-installed checkout of this repo's main branch — the "warm base" —
    and materializes agent workspaces from it copy-on-write.

    Building the warm base just FAILED. Diagnose and fix it, then verify locally.

    Repo: #{repo}
    Configured prewarm.base_build: #{cmd}

    Captured failure output:
    #{failure_output(reason)}

    Likely causes and what to do:
    - GitHub auth: cloning a private repo needs a valid GITHUB_TOKEN in .env whose
      account has read access (classic token `repo` scope, or fine-grained
      Contents: Read). If the token is missing or expired, tell the Executor
      exactly what to set — do not invent a secret.
    - Toolchain/build: if the repo cloned but base_build failed, detect this repo's
      real install + build command and write it into .aiur/config as
      prewarm.base_build. Route tool calls through `mise exec --`, cd into the
      directory holding the build manifest, use frozen/locked installs, and keep it
      idempotent and incremental. Do not mutate tracked source; no brew/apt/sudo.

    Then run the fix in a clean checkout, confirm it exits 0, run it a second time
    unchanged to confirm it is a near no-op, and report the final command (or the
    secret the Executor must set).
    """
  end

  @doc false
  @spec failure_output(term()) :: String.t()
  def failure_output({_tag, _status, out}) when is_binary(out),
    do: out |> String.trim() |> String.slice(0, 1500)

  def failure_output(reason), do: inspect(reason)
end
