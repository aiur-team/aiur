defmodule Aiur.RunTelemetry.FactsCLI do
  @moduledoc "Offline backfill entry point over the canonical governed PR-facts query."
  alias Aiur.Config.ObservabilitySettings
  alias Aiur.RunTelemetry.GitHubFacts

  @spec main([String.t()]) :: :ok
  def main(args) do
    case args do
      [repo | [_ | _] = tickets] -> IO.puts(Jason.encode!(Map.new(tickets, &{&1, fetch(&1, repo: repo)})))
      _ -> IO.puts(Jason.encode!(%{error: "invalid_arguments"}))
    end
  end

  @spec fetch(String.t(), keyword()) :: map()
  def fetch(ticket, opts \\ []) do
    enabled? = Keyword.get(opts, :enabled, fn -> ObservabilitySettings.telemetry_enabled?() and ObservabilitySettings.capture_github_facts?() end)
    fetch = Keyword.get(opts, :fetch, &GitHubFacts.fetch/2)

    if enabled?.() do
      case fetch.(ticket, Keyword.drop(opts, [:enabled, :fetch])) do
        {:ok, facts} -> %{facts: facts}
        {:error, reason} -> %{error: error_class(reason)}
      end
    else
      %{error: "disabled"}
    end
  end

  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(_reason), do: "facts_unavailable"
end
