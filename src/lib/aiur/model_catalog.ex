defmodule Aiur.ModelCatalog do
  @moduledoc """
  Asks a backend's own app-server which models it currently accepts.

  aiur's registry list (`Aiur.CodingAgent.backends/0`) is a baseline, not a
  source of truth — providers ship models faster than this repo is edited.
  Both supported CLIs answer a `model/list` request over the same
  JSON-line app-server transport dispatch already uses, and that CLI is
  precisely the thing that has to accept the model string, so it is the
  authority worth asking.

  Every failure — CLI not installed, offline, unreadable answer, slow
  start — comes back as `{:error, reason}`. Callers are expected to carry
  on with the registry baseline: discovery makes `aiur init` smarter, it
  must never be what stops it from finishing.
  """

  alias Aiur.AppServer.Messages
  alias Aiur.AppServer.Rpc
  alias Aiur.Claude.Config, as: ClaudeConfig
  alias Aiur.Codex.Config, as: CodexConfig
  alias Aiur.CodingAgent

  # Distinct from `Messages.initialize_id/0` so the initialize reply is never
  # mistaken for the model list.
  @model_list_id 9_307
  @probe_timeout_ms 20_000
  # Generous enough that a whole model catalogue arrives as one `:eol` line;
  # `:noeol` fragments are reassembled anyway.
  @port_line_bytes 1_000_000

  @type result :: {:ok, [String.t()]} | {:error, term()}
  @type probe :: (String.t(), keyword() -> {:ok, map()} | {:error, term()})

  @doc """
  Models the backend's installed CLI currently advertises, in the order it
  lists them (providers lead with their newest).

  Pass `probe: fun` to supply the raw `model/list` payload instead of
  spawning the real app-server.
  """
  @spec discover(CodingAgent.backend()) :: result()
  @spec discover(CodingAgent.backend(), keyword()) :: result()
  def discover(backend, opts \\ []) do
    probe = Keyword.get(opts, :probe, &probe_app_server/2)

    case CodingAgent.family_for(backend) do
      nil ->
        {:error, {:unknown_backend, backend}}

      family ->
        with {:ok, payload} <- probe.(family, opts) do
          extract(family, payload)
        end
    end
  end

  # codex advertises one entry per model; `hidden` entries are the ones its
  # own picker withholds, so aiur withholds them too.
  defp extract("codex", %{"data" => data}) when is_list(data) do
    models =
      data
      |> Enum.reject(&(Map.get(&1, "hidden") == true))
      |> Enum.map(&(Map.get(&1, "model") || Map.get(&1, "id")))
      |> Enum.filter(&is_binary/1)

    {:ok, Enum.uniq(models)}
  end

  # The claude app-server reports a full id plus the generic aliases that
  # resolve to it. Both are offered, with the alias first, and the id is
  # reduced to the `model:claude-<variant>` form aiur's registry and labels
  # use (`claude-sonnet-4-6` -> `sonnet-4-6`); `claude --model` accepts
  # either spelling.
  defp extract("claude", %{"models" => models}) when is_list(models) do
    names =
      Enum.flat_map(models, fn model ->
        aliases = model |> Map.get("aliases", []) |> Enum.filter(&is_binary/1)
        aliases ++ variant_name(Map.get(model, "id"))
      end)

    {:ok, Enum.uniq(names)}
  end

  defp extract(family, _payload), do: {:error, {:unexpected_model_list, family}}

  defp variant_name(id) when is_binary(id), do: [String.replace_prefix(id, "claude-", "")]
  defp variant_name(_id), do: []

  # One-shot `initialize` + `model/list` against the backend's app-server.
  # Spawned via `:spawn_executable` (no shell) and always reaped, including
  # on timeout, so a hung CLI can't outlive the wizard.
  @spec probe_app_server(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp probe_app_server(family, opts) do
    with {:ok, executable, args} <- resolve_command(family) do
      # `stderr_to_stdout` keeps an app-server's own diagnostics out of the
      # wizard's terminal — they arrive as non-JSON lines and are skipped.
      port =
        Port.open(
          {:spawn_executable, executable},
          [:binary, :exit_status, :stderr_to_stdout, {:line, @port_line_bytes}, args: args]
        )

      try do
        Rpc.send_line(port, Messages.initialize_frame())
        Rpc.send_line(port, %{"method" => "model/list", "id" => @model_list_id, "params" => %{}})
        await_model_list(port, deadline(opts), "")
      after
        close_port(port)
      end
    end
  end

  defp await_model_list(port, deadline, buffered) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :model_list_timeout}
    else
      receive_model_list(port, deadline, buffered, remaining)
    end
  end

  defp receive_model_list(port, deadline, buffered, remaining) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case decode_model_list(buffered <> chunk) do
          :skip -> await_model_list(port, deadline, "")
          resolved -> resolved
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_model_list(port, deadline, buffered <> chunk)

      {^port, {:exit_status, status}} ->
        {:error, {:model_list_exit, status}}
    after
      remaining -> {:error, :model_list_timeout}
    end
  end

  # Only the matching response id resolves the probe. Anything else on the
  # stream — the initialize reply, notifications, a stderr banner line — is
  # skipped rather than treated as an answer. A JSON-RPC error under our own
  # id ends the probe immediately: a backend whose app-server does not serve
  # `model/list` must not cost the wizard the full timeout.
  defp decode_model_list(line) do
    case Jason.decode(line) do
      {:ok, %{"id" => @model_list_id, "result" => result}} when is_map(result) -> {:ok, result}
      {:ok, %{"id" => @model_list_id, "error" => error}} -> {:error, {:model_list_error, error}}
      _other -> :skip
    end
  end

  defp deadline(opts) do
    System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @probe_timeout_ms)
  end

  # Closing the port EOFs the app-server's stdin, which is how both CLIs exit.
  # Lines that had already been queued stay in the caller's mailbox, so they are
  # drained too — otherwise a probe from a long-lived process would leak port
  # messages into its `handle_info`.
  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    flush_port(port)
  rescue
    ArgumentError -> flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _payload} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp resolve_command(family) do
    case family |> command_for() |> split_command() do
      [] ->
        {:error, {:no_command, family}}

      [exe | args] ->
        case System.find_executable(exe) do
          nil -> {:error, {:cli_unavailable, exe}}
          path -> {:ok, String.to_charlist(path), Enum.map(args, &String.to_charlist/1)}
        end
    end
  end

  defp split_command(command) when is_binary(command), do: String.split(String.trim(command), ~r/\s+/, trim: true)
  defp split_command(_command), do: []

  # `aiur init` is the main caller and reads the backend command from a config
  # that may not exist yet, so an unreadable command is a normal outcome here,
  # not a bug. Same `rescue` shape `Aiur.Init.AgentCli` uses for its own CLI
  # probes: no command means no discovery, never a crashed wizard.
  defp command_for(family) do
    case family do
      "codex" -> CodexConfig.command()
      "claude" -> ClaudeConfig.command()
      _other -> nil
    end
  rescue
    _error -> nil
  end
end
