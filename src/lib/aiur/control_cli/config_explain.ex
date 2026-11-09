defmodule Aiur.ControlCLI.ConfigExplain do
  @moduledoc false

  import Aiur.ControlCLI.Protocol

  alias Aiur.Config.Provenance
  alias Aiur.Orchestrator.Client

  @spec explain(String.t(), keyword()) :: :ok
  def explain(key, opts \\ []), do: explain(key, opts, [])

  # `provenance_opts` injects layer readers; it is not reachable through the allowlisted /2 call.
  @spec explain(String.t(), keyword(), keyword()) :: :ok
  def explain(key, opts, provenance_opts) when is_binary(key) and is_list(opts) do
    guarded("config explain #{key}", fn ->
      base = Keyword.merge([session_cap_fun: &session_cap/0], provenance_opts)

      case Provenance.explain(key, Keyword.merge(base, Keyword.take(opts, [:project]))) do
        {:ok, report} -> print(report, Keyword.get(opts, :json, false))
        {:error, reason} -> fail(reason)
      end
    end)
  end

  # `aiur set max-agents` is session-only orchestrator state, not an override entry.
  defp session_cap do
    case Client.max_concurrent_agents() do
      %{configured: configured, max: max} when is_integer(max) and max != configured -> max
      _ -> nil
    end
  end

  defp print(report, true) do
    IO.puts(Jason.encode!(report))
    exit_marker(0)
  end

  defp print(report, false) do
    IO.puts("#{report.key} = #{inspect(report.value)}")
    IO.puts("  owner #{report.layer} #{report.label}  #{report.source}")
    if report.capped_by, do: IO.puts("  capped by #{report.capped_by}")

    for o <- report.overridden,
        do: IO.puts("  overrode #{o.layer} #{o.label}  #{o.source} = #{inspect(o.value)}")

    for u <- report.unavailable,
        do: IO.puts("  unavailable #{u.layer} #{Provenance.labels()[u.layer]} (#{u.reason})")

    IO.puts("  as of #{report.observed_at} (age #{report.age_ms} ms, #{report.freshness})")
    exit_marker(0)
  end

  defp fail({:unknown_key, key, suggestions}) do
    hint = if suggestions == [], do: "", else: "; did you mean #{Enum.join(suggestions, ", ")}?"
    control_error("aiur: unknown config key #{key}#{hint}")
    exit_marker(64)
  end

  defp fail({:unknown_project, repo, known}) do
    control_error("aiur: unknown project #{repo}; configured: #{Enum.join(known, ", ")}")
    exit_marker(64)
  end

  defp fail({:project_required, known}) do
    control_error("aiur: this gateway serves several projects; pass --project (configured: #{Enum.join(known, ", ")})")
    exit_marker(64)
  end

  defp fail(reason) do
    control_error("aiur: config explain failed (#{inspect(reason)})")
    exit_marker(1)
  end
end
