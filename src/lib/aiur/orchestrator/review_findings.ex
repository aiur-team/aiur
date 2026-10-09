defmodule Aiur.Orchestrator.ReviewFindings do
  @moduledoc false

  # A body-only comment needs an explicit change signal; clean review summaries
  # must not bypass the unresolved-thread gate merely because they have prose.
  @spec blocking_body?(term()) :: boolean()
  def blocking_body?(body) when is_binary(body) do
    body = String.trim(body)

    not String.match?(body, ~r/\b(?:no (?:blockers|blocking (?:findings|issues))|all blockers (?:addressed|resolved))\b/i) and
      (String.match?(body, ~r/^(?:\s*\#{1,6})?\s*(?:blocking(?: findings| issues)?|blockers?|must fix|changes required)\s*:/im) or
         String.match?(body, ~r/\b(?:update|rebase|merge|fix)\b[^\n.!?]*\bbefore merge\b/i))
  end

  def blocking_body?(_body), do: false
end
