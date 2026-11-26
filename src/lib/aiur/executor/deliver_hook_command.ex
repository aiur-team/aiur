defmodule Aiur.Executor.DeliverHookCommand do
  @moduledoc """
  Generate a delivery hook that prints the daemon's envelope and always exits zero.

  Commands support a fixed URL or the daemon-written URL file for port changes.
  The credential is read on each invocation. A separate descriptor keeps it out
  of curl's argv without consuming the hook payload on stdin (Linux/macOS).
  curl streams successful responses, so a transfer timeout can leave partial output.
  """
  alias Aiur.Shell

  @spec command(:claude | :codex, String.t(), Path.t()) :: String.t()
  def command(harness, url, token_path)
      when harness in [:claude, :codex] and is_binary(url) and is_binary(token_path) do
    endpoint = String.trim_trailing(url, "/") <> "/api/v1/executor/hook/deliver?harness=#{harness}"

    script(Shell.escape(endpoint), token_path)
  end

  @spec from_url_file(:claude | :codex, Path.t(), Path.t()) :: String.t()
  def from_url_file(harness, url_path, token_path) when harness in [:claude, :codex] do
    "aiur_hook_url=$(cat " <>
      Shell.escape(url_path) <>
      " 2>/dev/null) || exit 0;\n" <>
      script("\"$aiur_hook_url/api/v1/executor/hook/deliver?harness=#{harness}\"", token_path)
  end

  defp script(endpoint, token_path) do
    "aiur_hook_token=$(cat " <>
      Shell.escape(token_path) <>
      " 2>/dev/null)\n" <>
      "curl -sS -f -m 3 -H 'Content-Type: application/json' -H @/dev/fd/3 " <>
      "--data-binary @- " <>
      endpoint <>
      " 3<<AIUR_EXECUTOR_AUTH 2>/dev/null; exit 0\n" <>
      "Authorization: Bearer $aiur_hook_token\nAIUR_EXECUTOR_AUTH\n"
  end
end
