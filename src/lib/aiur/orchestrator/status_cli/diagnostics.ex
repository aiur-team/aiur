defmodule Aiur.Orchestrator.StatusCLI.Diagnostics do
  @moduledoc false
  alias Aiur.BuildGate
  alias Aiur.Config
  alias Aiur.ExecutorListener
  alias Aiur.GitHub.CiReadiness
  alias Aiur.GitHub.CodeOwners
  alias Aiur.Orchestrator
  alias Aiur.RepoBase
  alias Aiur.SupervisionHealth

  @prewarm_warming_phases [:cloning, :fetching, :building, :checking]

  @doc false
  @spec print_global_pause_banner(term(), term()) :: term()
  def print_global_pause_banner(opts, timeout_ms) do
    result =
      Keyword.get_lazy(opts, :global_pause_status, fn ->
        Orchestrator.global_pause_status(Orchestrator, timeout_ms)
      end)

    case result do
      {:ok, %{globally_paused: true, paused_at: paused_at, source: source}} ->
        provenance =
          [format_pause_source(source), format_pause_time(paused_at)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(", ")

        suffix = if provenance == "", do: "", else: " (#{provenance})"

        IO.puts("GLOBALLY PAUSED#{suffix} — no agents will be provisioned (run `aiur resume` to lift)")

      {:ok, _} ->
        :ok

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :orchestrator_unavailable} ->
        {:error, :unavailable}
    end
  end

  defp format_pause_source(source) when is_binary(source) and source != "", do: "set by #{source}"
  defp format_pause_source(_), do: nil

  defp format_pause_time(%DateTime{} = paused_at), do: "at #{DateTime.to_iso8601(paused_at)}"
  defp format_pause_time(_), do: nil

  # Surface whether the daemon-resident Executor listener is currently
  # listening. The listener is now armed on every run, so absence no longer
  # means "no Executor was intended" — it means the recording path is broken and
  # this run is losing its wake stream. The check reflects the live Exchange
  # binding, not "was started once".
  @doc false
  @spec print_executor_listener_status() :: term()
  def print_executor_listener_status do
    bindings = Application.get_env(:aiur, :executor_listener_alive_fun, &ExecutorListener.bindings/0).()
    bindings = if is_list(bindings), do: bindings, else: if(bindings, do: ["executor.#"], else: [])
    defaults = Aiur.ExecutorBindings.patterns()
    bound = MapSet.new(bindings)
    missing = Enum.reject(defaults, &MapSet.member?(bound, &1))

    cond do
      bindings == [] ->
        IO.puts("LISTENER absent (FAULT: recording is armed on every run, so this means the wake path is broken; Commands and PR events are not being recorded)")

      missing == [] ->
        IO.puts("LISTENER present (#{length(defaults)} bindings: #{Enum.join(defaults, ", ")})")

      true ->
        IO.puts("LISTENER degraded (#{length(defaults) - length(missing)}/#{length(defaults)} bindings; MISSING: #{Enum.join(missing, ", ")})")
    end
  end

  @doc false
  @spec print_codeowners_trust() :: term()
  def print_codeowners_trust do
    snapshot =
      Application.get_env(:aiur, :agent_control_cli_trust_snapshot_fun, fn ->
        if Process.whereis(CodeOwners), do: CodeOwners.trust_snapshot(), else: nil
      end).()

    case snapshot do
      %{trusted: trusted, source: source} = snapshot when is_list(trusted) ->
        source = source |> to_string() |> String.downcase()
        path = snapshot |> Map.get(:path) |> trust_path()
        accounts = Enum.map_join(trusted, ", ", &"@#{&1}")
        suffix = if path, do: " path=#{path}", else: ""
        IO.puts("COMMENT TRUST source=#{source} trusted=[#{accounts}]#{suffix}#{CodeOwners.status_suffix(snapshot)}")

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp trust_path(path) when is_binary(path) do
    case Path.relative_to_cwd(path) do
      relative when relative != path -> relative
      _ -> path
    end
  end

  defp trust_path(_path), do: nil

  @doc false
  @spec print_build_gate_status() :: term()
  def print_build_gate_status do
    case BuildGate.status() do
      %{
        enabled?: true,
        capacity: capacity,
        active: active,
        queued: queued,
        degraded?: true,
        issues: [issue | remaining]
      } = status ->
        suffix = if remaining == [], do: "", else: " (+#{length(remaining)} more)"

        IO.puts(
          "BUILD GATE DEGRADED #{active}/#{capacity} active, #{queued} queued; " <>
            "max_concurrent_builds=#{capacity}; reason=#{issue.reason} path=#{issue.path}#{suffix}; " <>
            "recovery=#{issue.recovery}"
        )

        print_build_gate_holders(Map.get(status, :holders, []))
        print_build_gate_timeouts(Map.get(status, :timeouts, []))

      %{enabled?: true, capacity: capacity, active: active, queued: queued} = status
      when active > 0 or queued > 0 ->
        holders = Map.get(status, :holders, [])
        retain_seconds = Map.get(status, :retain_seconds)

        # A slot whose command process group is gone is not doing work: render
        # it apart from genuinely-busy slots so `BUILD GATE n/n active` never
        # reads as a confident wrong number (#2349).
        leaked = Enum.count(holders, &(&1.kind == :slot and &1.command_alive? == false))

        retain_suffix =
          if is_integer(retain_seconds) do
            ", retain_seconds=#{retain_seconds}"
          else
            ""
          end

        line =
          if leaked > 0 do
            "BUILD GATE #{active - leaked}/#{capacity} active, #{leaked} held without a command, " <>
              "#{queued} queued (max_concurrent_builds=#{capacity}#{retain_suffix})"
          else
            "BUILD GATE #{active}/#{capacity} active, #{queued} queued (max_concurrent_builds=#{capacity}#{retain_suffix})"
          end

        IO.puts(line)
        print_build_gate_holders(holders)
        print_build_gate_timeouts(Map.get(status, :timeouts, []))

      _ ->
        :ok
    end
  end

  # Name every lease currently held or queued so an operator can tell a
  # correctly-busy gate from one pinned by a leaked process (#2116). The
  # metadata is advisory: a record that cannot be parsed still leaves the
  # `active`/`queued` summary intact.
  defp print_build_gate_holders(holders) do
    Enum.each(holders, &print_build_gate_holder/1)
  end

  defp print_build_gate_holder(%{kind: :slot} = holder) do
    identifiers = ["slot=#{Map.get(holder, :slot)}", "pid=#{Map.get(holder, :pid)}"]
    annotation = if Map.get(holder, :command_alive?) == false, do: " (command gone)", else: if(Map.get(holder, :command_alive?) == nil, do: " (command liveness unknown)", else: "")
    print_build_gate_line("HOLDER", identifiers, holder, "held", annotation)
  end

  defp print_build_gate_holder(%{kind: :queue} = holder) do
    print_build_gate_line("QUEUED", ["pid=#{Map.get(holder, :pid)}"], holder, "waiting")
  end

  defp print_build_gate_holder(_holder), do: :ok

  # A `slot-N.hold-timeout` marker means the detached holder released the lease
  # at the absolute max-hold cap (#2349). Surface it so `aiur status` shows a
  # slot that timed out as well as one that is merely still held.
  defp print_build_gate_timeouts(timeouts) do
    Enum.each(timeouts, fn timeout ->
      IO.puts(
        "BUILD GATE TIMEOUT slot=#{timeout.slot} command=#{inspect(timeout.command)} " <>
          "held=#{format_gate_hold(timeout.held_for_seconds)} reason=#{timeout.reason}"
      )
    end)
  end

  defp print_build_gate_line(kind, identifiers, holder, duration_label) do
    print_build_gate_line(kind, identifiers, holder, duration_label, "")
  end

  defp print_build_gate_line(kind, identifiers, holder, duration_label, annotation) do
    with pid when is_integer(pid) <- Map.get(holder, :pid),
         command when is_binary(command) <- Map.get(holder, :command) do
      IO.puts(
        "BUILD GATE #{kind} #{Enum.join(identifiers, " ")} command=#{inspect(command)} " <>
          "#{duration_label}=#{format_gate_hold(Map.get(holder, :held_for_seconds))}#{annotation}"
      )
    else
      _ -> :ok
    end
  end

  defp format_gate_hold(nil), do: "unknown"

  defp format_gate_hold(seconds) when is_integer(seconds) and seconds >= 3_600 do
    "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m"
  end

  defp format_gate_hold(seconds) when is_integer(seconds) and seconds >= 60 do
    "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
  end

  defp format_gate_hold(seconds) when is_integer(seconds) and seconds >= 0, do: "#{seconds}s"
  defp format_gate_hold(_seconds), do: "unknown"

  @doc false
  @spec print_supervision_health() :: term()
  def print_supervision_health do
    health_status =
      Application.get_env(:aiur, :supervision_health_status_fun, &SupervisionHealth.status/0)

    case health_status.() do
      {:ok, %{missing: []} = snapshot} ->
        IO.puts(SupervisionHealth.format(snapshot))
        0

      {:ok, snapshot} ->
        IO.puts(SupervisionHealth.format(snapshot))
        1

      {:error, :unavailable} ->
        IO.puts("SUPERVISION unavailable")
        1
    end
  end

  @doc false
  @spec print_ci_readiness() :: term()
  def print_ci_readiness do
    if Config.tracker_kind() == "github" do
      case CiReadiness.cached_result() do
        :unavailable -> IO.puts("CI readiness: unavailable (no completed dispatcher assessment)")
        readiness -> IO.puts(CiReadiness.format(readiness))
      end
    end
  end

  # Surface the warm-base state so a gated fleet is distinguishable from an idle
  # one (#1404): with prewarm enabled, a warming base holds dispatch on every
  # poll tick and an errored base degrades to cold clones. A :ready base is the
  # normal steady state and prints nothing. No-op when prewarm is disabled or
  # RepoBase is not running.
  @doc false
  @spec print_prewarm_status() :: term()
  def print_prewarm_status do
    if Config.prewarm_enabled?() do
      case prewarm_status_safe() do
        {phase, _base} when phase in @prewarm_warming_phases ->
          IO.puts("PREWARM prewarm: warming phase=#{phase} — dispatch held while the base build completes")

        {{:error, reason}, _base} ->
          IO.puts("PREWARM prewarm: unavailable reason=#{inspect(reason)} — dispatching via cold clone")

        _steady_or_unknown ->
          :ok
      end
    end
  end

  defp prewarm_status_safe do
    if Process.whereis(RepoBase), do: RepoBase.status(), else: {:idle, nil}
  rescue
    _ -> {:idle, nil}
  catch
    :exit, _ -> {:idle, nil}
  end
end
