defmodule Aiur.ControlCLI.ExecutorRequest do
  @moduledoc "Creates human-directed Commands attributed to the requesting Executor."

  alias Aiur.Commands
  alias Aiur.ControlCLI.MediaSpec
  alias Aiur.ControlCLI.PendingCommands

  @spec request(keyword(), keyword()) :: 0 | 1 | 64
  def request(params, deps \\ []) do
    with :ok <- validate_text(params),
         {:ok, options} <- options(Keyword.get(params, :options, [])),
         {:ok, options, recommendation} <- recommend(options, params[:recommend]),
         {:ok, media, options} <- media(Keyword.get(params, :media, []), options),
         :ok <- validate_identity(params[:executor_id]),
         {:ok, blockers} <- blockers(params[:after]) do
      if blockers == [], do: submit(params, options, recommendation, media, deps), else: defer(params, blockers, deps)
    else
      {:error, reason} -> error(deps, reason, 64)
    end
  end

  defp validate_text(params) do
    invalid? = params |> Enum.flat_map(fn {_key, value} -> List.wrap(value) end) |> Enum.any?(fn value -> is_binary(value) and not String.valid?(value) end)
    if invalid?, do: {:error, "text must be valid UTF-8"}, else: :ok
  end

  # The launcher resolves identity on the caller's machine before RPC.
  defp validate_identity(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_identity(_id), do: {:error, "requester identity is required"}

  @doc "Cancels a pending `--after` Command before it publishes."
  @spec cancel(keyword(), keyword()) :: 0 | 1 | 64
  def cancel(params, deps \\ []) do
    id = params[:pending_id]
    report = Keyword.get(deps, :error_fun, &IO.puts(:stderr, &1))

    case PendingCommands.cancel(id, Keyword.get(deps, :pending_server, PendingCommands)) do
      {:ok, _entry} ->
        IO.puts("Cancelled pending Command #{id}")
        0

      {:error, :not_found} ->
        report.("aiur: command cancel found no pending Command #{id}")
        64

      {:error, reason} ->
        report.("aiur: command cancel failed (#{inspect(reason)})")
        1
    end
  end

  defp blockers(nil), do: {:ok, []}
  defp blockers(raw), do: PendingCommands.parse_after(raw)

  # Media is re-validated at publication, when the request runs again without --after.
  defp defer(params, blockers, deps) do
    case PendingCommands.defer(params, blockers, Keyword.get(deps, :pending_server, PendingCommands)) do
      {:ok, entry} ->
        print_pending(entry, params[:json])
        0

      # A refusal names the blocker that cannot work; nothing was stored.
      {:error, reason} when is_binary(reason) ->
        error(deps, "--after refused: #{reason}", 64)

      {:error, reason} ->
        error(deps, "cannot store pending Command (#{inspect(reason)})", 1)
    end
  end

  defp print_pending(entry, true),
    do: IO.puts(Jason.encode!(%{pending_id: entry["id"], after: entry["after"], status: entry["status"], source_id: entry["params"]["idempotency_key"]}))

  defp print_pending(%{"status" => "published"} = entry, _json) do
    IO.puts("Every ticket after #{Enum.map_join(entry["after"], ", ", &"##{&1}")} has merged; published the Command now")
    IO.puts("Idempotency key: #{entry["params"]["idempotency_key"]}\nView: aiur command")
  end

  defp print_pending(entry, _json) do
    IO.puts("Pending Command #{entry["id"]}: publishes after #{Enum.map_join(entry["after"], ", ", &"##{&1}")} merge")
    IO.puts("Cancel: aiur command cancel #{entry["id"]}\nView: aiur command")
  end

  defp submit(params, options, recommendation, media, deps) do
    executor_id = params[:executor_id]
    source_id = params[:idempotency_key] || "exec-#{Ecto.UUID.generate()}"

    payload = %{
      question: params[:question],
      options: options,
      media: media,
      recommendation: recommendation,
      authority: :human_required,
      blocking: Keyword.get(params, :blocking, true),
      urgency: Keyword.get(params, :urgency, "normal"),
      source_id: source_id,
      context: %{short_summary: params[:short_summary], long_context_markdown: params[:long_context_markdown]}
    }

    opts = [
      ticket: %{identifier: "executor"},
      source: %{agent_id: "executor", session_id: executor_id, event_id: source_id},
      requester: %{kind: :executor, executor_id: executor_id, ticket: params[:ticket]},
      origin: :executor_cli
    ]

    case record(payload, opts, deps) do
      {:ok, %{decision: decision, status: status}} ->
        Keyword.get(deps, :result_fun, &print_result/4).(decision, status, source_id, params[:json])
        0

      {:error, reason} ->
        error(deps, "cannot create Command (#{inspect(reason)}); idempotency key: #{source_id}", error_code(reason))
    end
  end

  defp record(payload, opts, deps) do
    Commands.request(payload, opts, Keyword.get(deps, :decision_store, Commands.default_store()))
  catch
    :exit, _reason -> {:error, :daemon_unavailable}
  end

  defp error_code({:decision_invalid, _reason}), do: 64
  defp error_code(_reason), do: 1

  defp options(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [id, label] when id != "" and label != "" -> {:cont, {:ok, acc ++ [%{id: id, label: label}]}}
        _ -> {:halt, {:error, "--option expects id=label"}}
      end
    end)
  end

  # Items stay untrusted here; the request validation applies the media contract.
  defp media(specs, options) do
    Enum.reduce_while(specs, {:ok, [], options}, fn spec, {:ok, prompt, options} ->
      case MediaSpec.parse(spec) do
        {:ok, {nil, item}} -> {:cont, {:ok, prompt ++ [item], options}}
        {:ok, {id, item}} -> attach(id, item, prompt, options)
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp attach(id, item, prompt, options) do
    if Enum.any?(options, &(&1.id == id)) do
      {:cont, {:ok, prompt, Enum.map(options, &if(&1.id == id, do: Map.update(&1, :media, [item], fn media -> media ++ [item] end), else: &1))}}
    else
      {:halt, {:error, "--media option=#{id} must name one supplied option"}}
    end
  end

  defp recommend(options, nil), do: {:ok, options, nil}

  defp recommend(options, id) do
    case Enum.split_with(options, &(&1.id == id)) do
      {[option], others} -> {:ok, [option | others], %{option_id: id}}
      _ -> {:error, "--recommend must name one supplied option"}
    end
  end

  defp print_result(decision, status, source_id, true) do
    IO.puts(Jason.encode!(%{decision_id: decision.decision_id, version: decision.version, route_state: decision.route_state, source_id: source_id, status: status}))
  end

  defp print_result(decision, status, source_id, _json) do
    verb = if status == :duplicate, do: "Existing", else: "Created"
    IO.puts("#{verb} Command #{decision.decision_id} (needs you)")
    IO.puts("Idempotency key: #{source_id}\nView: aiur commands #{decision.decision_id}")
  end

  defp error(deps, message, code) do
    Keyword.get(deps, :error_fun, &IO.puts(:stderr, &1)).("aiur: command request #{message}")
    code
  end
end
