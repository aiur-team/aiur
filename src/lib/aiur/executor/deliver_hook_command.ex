defmodule Aiur.Executor.DeliverHookCommand do
  @moduledoc """
  Generate a delivery hook that prints the daemon's envelope and always exits zero.

  The URL is captured at installation; port changes require reinstalling the hook.
  The credential is read on each invocation. A separate descriptor keeps it out
  of curl's argv without consuming the hook payload on stdin (Linux/macOS).
  curl streams successful responses, so a transfer timeout can leave partial output.
  """
  alias Aiur.Shell

  @spec command(:claude | :codex, String.t(), Path.t()) :: String.t()
  def command(harness, url, token_path)
      when harness in [:claude, :codex] and is_binary(url) and is_binary(token_path) do
    endpoint = String.trim_trailing(url, "/") <> "/api/v1/executor/hook/deliver?harness=#{harness}"

    "curl -sS -f -m 3 -H 'Content-Type: application/json' -H @/dev/fd/3 " <>
      "--data-binary @- " <>
      Shell.escape(endpoint) <>
      " 3<<AIUR_EXECUTOR_AUTH 2>/dev/null; exit 0\n" <>
      "Authorization: Bearer $(cat " <> Shell.escape(token_path) <> " 2>/dev/null)\nAIUR_EXECUTOR_AUTH\n"
  end
end
