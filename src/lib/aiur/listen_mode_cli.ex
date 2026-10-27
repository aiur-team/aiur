defmodule Aiur.ListenModeCli do
  @moduledoc "Read and compare-and-set ticket listener modes from the shared launcher."
  import Aiur.ControlCLI.Protocol
  alias Aiur.Listener

  @switches [
    json: :boolean,
    expected_version: :integer,
    idempotency_key: :string,
    actor: :string
  ]

  @spec run(String.t(), [String.t()]) :: :ok
  def run(ticket, argv) do
    guarded("listen-mode", fn ->
      {opts, modes, invalid} = OptionParser.parse(argv, strict: @switches)
      key = opts[:idempotency_key] || "cli-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      result = if invalid == [], do: execute(ticket, modes, opts, key), else: {:error, :invalid_arguments}
      report(result, opts, key) |> exit_marker()
    end)
  end

  defp execute(ticket, [], _opts, _key), do: Listener.get_mode(ticket)

  defp execute(ticket, [mode], opts, key) when mode in ["steer", "sync", "async"] do
    actor = opts[:actor] || "human"

    if actor in ["human", "executor"] do
      with {:ok, current} <- Listener.get_mode(ticket) do
        version = Keyword.get(opts, :expected_version, current.version)

        result =
          Listener.set_mode(ticket, String.to_existing_atom(mode),
            expected_version: version,
            actor: String.to_existing_atom(actor),
            idempotency_key: key
          )

        case result do
          {:error, {:outcome_unknown, _}} -> {:error, {:outcome_unknown, %{expected_version: version}}}
          other -> other
        end
      end
    else
      {:error, :invalid_actor}
    end
  end

  defp execute(_ticket, _modes, _opts, _key), do: {:error, :invalid_mode}

  defp report({:ok, record}, opts, _key) do
    print_record(record, opts)
    0
  end

  defp report({:error, {:mode_conflict, current}}, opts, _key) do
    IO.puts("aiur: mode_conflict")
    print_record(current, opts)
    3
  end

  defp report({:error, {:outcome_unknown, info}}, _opts, key) do
    IO.puts("aiur: outcome unknown; retry with the same mode, --expected-version #{info.expected_version} and --idempotency-key #{key}")
    124
  end

  defp report({:error, reason}, _opts, _key) do
    IO.puts("aiur: listen-mode failed: #{inspect(reason)}")
    if reason in [:timeout, :unavailable], do: 124, else: 1
  end

  defp print_record(record, opts) do
    record = Map.merge(record, %{observed_at: DateTime.to_iso8601(DateTime.utc_now()), age_ms: 0, freshness: :fresh, routing: :legacy})

    if opts[:json] do
      IO.puts(Jason.encode!(record))
    else
      IO.puts("aiur: requested #{record.requested}; effective #{record.effective || "unknown"}; reason #{record.effective_reason || "none"}; version #{record.version}; actor #{record.actor}")
      IO.puts("aiur: legacy routing ignores the stored mode")
    end
  end
end
