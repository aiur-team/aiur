defmodule Aiur.Toolchain do
  @moduledoc """
  Toolchain drift check (#7443).

  At boot and then hourly, probes the CLIs workers spawn (`aiur-claude`,
  `claude`, `codex`) and the `aiur` launcher on the PATH workers inherit. A
  version below Aiur's minimum raises `system.toolchain.below_minimum` and holds
  dispatch to that backend; a version behind npm's latest is a warning in
  `aiur status` with the command to update.

  With `toolchain.auto_update: true`, a managed npm install that is behind is
  updated while its backend's dispatch is held and no worker of that backend is
  running. Running agents keep the binary they started with; new spawns use the
  new one. An `npm link` and the `aiur` launcher itself are never replaced.

  Readers use the published snapshot, so neither `aiur status` nor dispatch
  ever waits on a probe.
  """

  use GenServer
  require Logger

  alias Aiur.{AlertFeed, CodingAgent, Config, Issue, Signal}
  alias Aiur.Config.RoutingValue
  alias Aiur.Toolchain.Probe

  @alert "system.toolchain.below_minimum"
  @interval_ms :timer.hours(1)
  @key {__MODULE__, :snapshot}
  @held [:below_minimum, :updating]

  @spec alert_name() :: String.t()
  def alert_name, do: @alert

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :probe_on_start, true), do: send(self(), :check)
    {:ok, opts}
  end

  @impl true
  def handle_info(:check, opts) do
    check(opts)
    Process.send_after(self(), :check, @interval_ms)
    {:noreply, opts}
  end

  @doc "The CLIs Aiur checks, resolved from the same backend config workers launch with."
  @spec tools() :: [map()]
  def tools do
    [
      %{name: "aiur-claude", exe: executable("claude"), package: "aiur-claude", backends: ["claude"], minimum: get_in(CodingAgent.backends(), ["claude", :minimum_version]), auto_update?: true},
      %{name: "claude", exe: executable("claude-repl"), package: "@anthropic-ai/claude-code", backends: ["claude-repl"], minimum: nil, auto_update?: true},
      %{name: "codex", exe: executable("codex"), package: "@openai/codex", backends: ["codex"], minimum: nil, auto_update?: true},
      # Replacing the launcher under a live daemon is a restart, not an update.
      %{name: "aiur", exe: "aiur", package: "aiur-cli", backends: [], minimum: nil, auto_update?: false}
    ]
  end

  # The first word of the backend command a worker launches.
  defp executable(backend) do
    command = Config.backend_config(backend)["command"] || get_in(CodingAgent.backends(), [backend, :default_command])
    if is_binary(command), do: command |> String.split() |> List.first()
  end

  @doc """
  Probes every tool, publishes the snapshot, applies auto-update when enabled,
  and raises or resolves the below-minimum attention. Options override the
  tool list (`:tools`), the probe (`:path`, `:runner`, `:latest`), auto-update
  (`:auto_update?`, `:install`, `:running_backends`) and the clock (`:now`).
  """
  @spec check(keyword()) :: [Probe.result()]
  def check(opts \\ []) do
    probe_opts = probe_opts(opts)
    tools = Keyword.get_lazy(opts, :tools, &tools/0) |> Enum.map(&Probe.run(&1, probe_opts))
    publish(tools, opts)

    tools =
      if auto_update?(opts),
        do: tools |> Enum.map(&maybe_update(&1, tools, probe_opts, opts)) |> tap(&publish(&1, opts)),
        else: tools

    Enum.each(tools, &log_behind/1)
    alert(tools)
    tools
  end

  defp probe_opts(opts) do
    fetch = Keyword.get_lazy(opts, :latest, &default_latest/0)
    Keyword.take(opts, [:path, :runner]) ++ [latest: cached_latest(fetch, opts)]
  end

  defp default_latest, do: if(Config.upgrade_check_enabled?(), do: &Probe.npm_latest/1, else: fn _package -> nil end)

  # npm's latest version is reused from the published snapshot for one probe
  # interval, so a re-run check (a GenServer restart, a manual call) does not
  # spawn `npm view` again. An unknown latest is never cached.
  defp cached_latest(fetch, opts) do
    fresh = fresh_latest(snapshot(), Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
    fn package -> Map.get_lazy(fresh, package, fn -> fetch.(package) end) end
  end

  defp fresh_latest(%{observed_at: at, tools: tools}, now) do
    if DateTime.diff(now, at, :millisecond) < @interval_ms,
      do: for(%{latest: version} = tool <- tools, is_binary(version), into: %{}, do: {tool.package, version}),
      else: %{}
  end

  defp fresh_latest(nil, _now), do: %{}

  defp auto_update?(opts) do
    Keyword.get_lazy(opts, :auto_update?, fn -> match?({:ok, %{toolchain: %{auto_update: true}}}, Config.settings()) end)
  end

  @spec snapshot() :: %{observed_at: DateTime.t(), tools: [Probe.result()]} | nil
  def snapshot, do: :persistent_term.get(@key, nil)

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp publish(tools, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    :persistent_term.put(@key, %{observed_at: now, tools: tools})
  end

  defp replace(tools, tool), do: Enum.map(tools, &if(&1.name == tool.name, do: tool, else: &1))

  @doc """
  `CodingAgent.select_for_dispatch/2` with held backends (CLI below the minimum
  or mid-update) treated as unavailable routes, so selection falls through to
  the next allowed route. The ticket is held only when the backend it would
  still spawn — a `model:` pin, the routed default, or the fallback once every
  route is held — is itself held.
  """
  @spec select_for_dispatch(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:all_limited, [String.t()]} | {:error, {:toolchain_hold, String.t()}}
  def select_for_dispatch(%Issue{} = issue, opts \\ []) do
    case held_tools() do
      [] ->
        CodingAgent.select_for_dispatch(issue, opts)

      held ->
        skip_held = fn routes -> Enum.reject(routes, &hold_for(held, RoutingValue.routing_backend(&1))) end

        issue
        |> CodingAgent.select_for_dispatch(Keyword.update(opts, :route_policies, [skip_held], &[skip_held | &1]))
        |> hold_selected(held)
    end
  end

  # The selection still lands on a held backend: a pin, the routed default, or
  # the fallback once every route is held.
  defp hold_selected({:ok, selected}, held) do
    case hold_for(held, CodingAgent.backend_for(selected)) do
      nil -> {:ok, selected}
      tool -> {:error, {:toolchain_hold, hold_detail(tool)}}
    end
  end

  defp hold_selected(other, _held), do: other

  defp hold_detail(%{status: :updating} = tool), do: "#{tool.name} is updating to #{tool.latest}"
  defp hold_detail(tool), do: "#{tool.name} #{tool.version} is below the minimum #{tool.minimum}; #{update_hint(tool)}"

  defp held_tools do
    case snapshot() do
      %{tools: tools} -> Enum.filter(tools, &(&1.status in @held))
      nil -> []
    end
  end

  defp hold_for(held, backend), do: Enum.find(held, &(backend in &1.backends))

  defp maybe_update(%{auto_update?: true, kind: :npm, status: status, latest: latest} = tool, tools, probe_opts, opts)
       when status in [:behind, :below_minimum] and is_binary(latest) do
    if Probe.older?(tool.version, latest), do: update(tool, tools, probe_opts, opts), else: tool
  end

  defp maybe_update(tool, _tools, _probe_opts, _opts), do: tool

  # Hold the backend first, then look for its workers, so nothing spawns the
  # binary between the check and the install.
  defp update(tool, tools, probe_opts, opts) do
    publish(replace(tools, %{tool | status: :updating}), opts)

    result =
      if busy?(tool, opts) do
        Logger.info("Toolchain auto-update of #{tool.name} deferred: a #{Enum.join(tool.backends, "/")} worker is running")
        tool
      else
        install(tool, probe_opts, opts)
      end

    publish(replace(tools, result), opts)
    result
  end

  defp install(tool, probe_opts, opts) do
    install = Keyword.get(opts, :install, &Probe.npm_install/2)
    Logger.info("Toolchain auto-update: #{tool.name} #{tool.version} -> #{tool.latest} (npm install -g #{tool.package}@#{tool.latest})")

    case install.(tool.package, tool.latest) do
      :ok -> tool |> Map.take([:name, :exe, :package, :backends, :minimum, :auto_update?]) |> Probe.run(probe_opts) |> log_update(tool)
      {:error, reason} -> tap(tool, fn _ -> Logger.warning("Toolchain auto-update of #{tool.name} failed: #{reason}") end)
    end
  end

  defp log_update(updated, before) do
    if updated.version == before.version,
      do: Logger.warning("Toolchain auto-update of #{before.name} left #{updated.path} at #{updated.version}; another install shadows it on PATH"),
      else: Logger.info("Toolchain auto-update: #{before.name} is now #{updated.version} at #{updated.path}")

    updated
  end

  # ponytail: reads the published fleet snapshot, which can trail a dispatch by
  # one publish; a worker whose backend is not yet known counts as busy.
  defp busy?(tool, opts) do
    case Keyword.get(opts, :running_backends, &running_backends/0).() do
      backends when is_list(backends) -> Enum.any?(backends, &(is_nil(&1) or &1 in tool.backends))
      _unavailable -> true
    end
  end

  defp running_backends do
    case Aiur.Orchestrator.fleet_view(Aiur.Orchestrator, 2_000) do
      {:ok, %{running: running}, _freshness} when is_list(running) -> Enum.map(running, &Map.get(&1, :backend))
      _unavailable -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp log_behind(%{status: :behind} = tool), do: Logger.warning("Toolchain: #{tool.name} #{tool.version} is behind #{tool.latest}; #{update_hint(tool)}")
  defp log_behind(_tool), do: :ok

  defp alert(tools) do
    case Enum.filter(tools, &(&1.status == :below_minimum)) do
      [] -> resolve_attention()
      below -> raise_attention(below)
    end
  end

  defp raise_attention(below) do
    unless AlertFeed.condition_state(@alert) == :firing do
      detail = Enum.map_join(below, "; ", &"#{&1.name} #{&1.version} at #{&1.path} is below #{&1.minimum} (#{Enum.join(&1.backends, "/")} dispatch held; #{update_hint(&1)})")

      Signal.alert(@alert,
        message: "A worker CLI is below Aiur's minimum version; its backend's dispatch is held.",
        reason: "A worker CLI is below Aiur's minimum version: #{detail}",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  defp resolve_attention do
    if AlertFeed.condition_state(@alert) == :firing do
      Signal.alert(@alert <> ".resolved",
        message: "Worker CLIs meet Aiur's minimum versions again.",
        reason: "Worker CLIs meet Aiur's minimum versions; held backends may dispatch again.",
        needs_attention: false,
        severity: "info"
      )
    end

    :ok
  end

  @doc "The command an operator runs to bring `tool` up to date."
  @spec update_hint(map()) :: String.t()
  def update_hint(%{kind: :dev_link, path: path}), do: "dev link: rebuild the linked checkout behind #{Probe.realpath(path)}"
  def update_hint(%{kind: :standalone, name: name}), do: "update #{name} with the installer that put it on PATH"
  def update_hint(%{name: "aiur", package: package}), do: "update: npm install -g #{package}@latest, then aiur restart"
  def update_hint(%{package: package}), do: "update: npm install -g #{package}@latest"

  @spec print_status(keyword()) :: :ok
  def print_status(opts \\ []), do: Enum.each(status_lines(snapshot(), opts), &IO.puts/1)

  @doc "The `aiur status` TOOLCHAIN section."
  @spec status_lines(map() | nil, keyword()) :: [String.t()]
  def status_lines(snapshot, opts \\ [])
  def status_lines(nil, _opts), do: ["TOOLCHAIN unavailable (not checked yet)"]

  def status_lines(%{observed_at: observed_at, tools: tools}, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ["TOOLCHAIN observed_at=#{DateTime.to_iso8601(observed_at)} age_ms=#{DateTime.diff(now, observed_at, :millisecond)}" | Enum.map(tools, &("  " <> tool_line(&1)))]
  end

  defp tool_line(%{status: :missing} = tool), do: "#{tool.name} not on PATH"
  defp tool_line(%{status: :unknown} = tool), do: "#{tool.name} version unknown #{kind_label(tool)} #{tool.path}"

  defp tool_line(tool) do
    "#{tool.name} #{tool.version} #{kind_label(tool)} #{tool.path} " <>
      case tool.status do
        :below_minimum -> "BELOW MINIMUM #{tool.minimum}, #{Enum.join(tool.backends, "/")} dispatch held; #{update_hint(tool)}"
        :updating -> "updating to #{tool.latest}, #{Enum.join(tool.backends, "/")} dispatch held"
        :behind -> "WARNING behind #{tool.latest}; #{update_hint(tool)}"
        :latest_unknown -> "latest unknown"
        :current -> "current"
      end
  end

  defp kind_label(%{kind: :dev_link}), do: "(dev link)"
  defp kind_label(%{kind: kind}), do: "(#{kind})"
end
