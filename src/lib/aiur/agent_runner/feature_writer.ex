defmodule Aiur.AgentRunner.FeatureWriter do
  @moduledoc false

  @spec write(map(), map(), keyword()) :: {:ok, map()} | {:error, term()} | {:usage, String.t()}
  def write(issue, args, opts \\ []) do
    with {:ok, identifier} <- bound_number(Map.get(issue, :identifier)) do
      actor = "agent:" <> identifier
      source = if Map.get(args, :backfill, false), do: "backfill-agent", else: actor
      Aiur.FeatureCLI.apply_op(args, Keyword.merge(opts, actor: actor, source: source))
    end
  end

  defp bound_number(identifier) when is_binary(identifier) do
    if Regex.match?(~r/^[1-9][0-9]{0,9}\z/, identifier) and String.to_integer(identifier) < 2_147_483_648 do
      {:ok, identifier}
    else
      {:error, :feature_tool_needs_github_issue}
    end
  end

  defp bound_number(_), do: {:error, :feature_tool_needs_github_issue}
end
