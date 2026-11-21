defmodule Aiur.Executor.Capability do
  @moduledoc "Pure read capability projection for an attached Executor snapshot."

  @type status :: :proven | :untested | :unsupported | :unknown

  @spec read() :: map()
  def read do
    snapshot =
      case Aiur.Executor.Session.current() do
        {:ok, binding} -> binding
        :none -> nil
      end

    read(snapshot)
  catch
    :exit, _reason -> read(nil)
  end

  @spec read(map() | nil, map(), DateTime.t()) :: map()
  def read(snapshot, ingest, now), do: capability(snapshot, now, ingest)

  @spec read(map() | nil) :: map()
  def read(snapshot) do
    capability(snapshot, DateTime.utc_now())
  end

  @spec capability(map() | nil, DateTime.t()) :: map()
  def capability(snapshot, now), do: capability(snapshot, now, %{})

  @spec capability(map() | nil, DateTime.t(), map()) :: map()
  def capability(snapshot, now, ingest) do
    binding = if is_map(snapshot), do: snapshot, else: %{}
    {status, reason, cli_version} = classify(binding, ingest)

    %{
      harness: Map.get(binding, :harness),
      cli_version: cli_version,
      status: status,
      reason: reason,
      tested_range: tested_range(binding),
      observed_at: DateTime.to_iso8601(now)
    }
  end

  @spec identity_entry(map()) :: map()
  def identity_entry(%{status: :proven}), do: %{state: :available}
  def identity_entry(%{status: :untested, reason: reason}), do: %{state: :degraded, reason: :unknown, detail: Atom.to_string(reason)}
  def identity_entry(%{status: :unsupported, reason: reason}), do: %{state: :unavailable, reason: :unknown, detail: Atom.to_string(reason)}
  def identity_entry(%{status: :unknown}), do: %{state: :unavailable, reason: :unknown, detail: "unknown"}

  defp classify(%{state: "detached"}, _ingest), do: {:unknown, :not_attached, nil}
  defp classify(%{state: "awaiting_first_hook"}, _ingest), do: {:unknown, :awaiting_first_hook, nil}

  defp classify(%{harness: "codex"}, %{transcript_rejection: :unsupported_layout}), do: {:unsupported, :layout_unknown, nil}
  defp classify(%{harness: "codex"}, %{codex_rollout: :unsupported}), do: {:unsupported, :codex_reader_unavailable, nil}
  defp classify(%{harness: "codex", codex_cli_version: version}, %{codex_rollout: :untested}), do: {:untested, :version_untested, version}
  defp classify(%{harness: "codex", state: "attached", codex_cli_version: version}, %{codex_rollout: :tested}), do: {:proven, nil, version}
  defp classify(%{harness: "claude", transcript_format: %{"alerted" => true} = format}, _ingest), do: {:untested, :format_drift, format["untested_version"]}

  defp classify(%{harness: "claude", transcript_format: %{"versions" => %{"tested" => tested}, "tested_version" => version}}, _ingest)
       when tested > 0,
       do: {:proven, nil, version}

  defp classify(%{harness: "claude"}, %{transcript_rejection: reason}) when not is_nil(reason), do: {:unknown, :source_unreadable, nil}
  defp classify(_snapshot, _ingest), do: {:unknown, :awaiting_first_hook, nil}

  defp tested_range(%{harness: "codex"}), do: "0.171.x"
  defp tested_range(%{harness: "claude"}), do: "2.1.287–2.1.299"
  defp tested_range(_binding), do: nil
end
