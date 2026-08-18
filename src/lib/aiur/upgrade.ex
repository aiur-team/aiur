defmodule Aiur.Upgrade do
  @moduledoc """
  Channel-aware upgrade version notice for `aiur run`.

  The npm registry distributes aiur across three dist-tags — `latest`, `next`,
  and `nightly` — and today `latest` (0.0.3) is *older* than published nightlies
  (`0.0.5-nightly.<sha>`). A naive "compare against `latest`" check would tell a
  nightly or `next` user to downgrade. This module resolves the user's own
  channel and compares within it, never offering a lower version, and says so
  plainly when a user's channel stops publishing.

  The check is deliberately optional and non-invasive:

    * it never blocks boot — it runs in a fire-and-forget task;
    * it fails open and silent — an offline/errored registry yields no notice;
    * it caches with a TTL — the registry is contacted at most once a day;
    * it is disable-able via the `upgrade.check_enabled` config key or the
      `AIUR_UPGRADE_CHECK_DISABLED` environment variable;
    * it says nothing under a development launcher (`aiurdev`), where the local
      tree is routinely ahead of every published version.
  """

  require Logger

  alias Aiur.Upgrade.{Registry, State, Version}

  @check_interval_ms 24 * 60 * 60 * 1000
  @gone_prefix "gone:"

  @doc """
  Whether the upgrade check is enabled by config. Defaults to true; set
  `upgrade.check_enabled: false` to suppress the check entirely. Accepts a
  pre-parsed settings value (e.g. `{:ok, %Aiur.Config.Schema{}}`) for tests;
  nil reads the live config and fails open to enabled.
  """
  @spec check_enabled?(term() | nil) :: boolean()
  def check_enabled?(settings \\ nil) do
    Aiur.Config.upgrade_check_enabled?(settings || Aiur.Config.settings_uncached())
  end

  @doc """
  True when the check must stay completely silent: an explicit env opt-out
  (`AIUR_UPGRADE_CHECK_DISABLED`, or the legacy `AIUR_NO_UPDATE_NOTIFIER`), a CI
  run, or `upgrade.check_enabled: false` in config.
  """
  @spec disabled?(term() | nil) :: boolean()
  def disabled?(settings \\ nil) do
    env_disabled?() or ci?() or not check_enabled?(settings)
  end

  @doc """
  True when running under a development launcher (`aiurdev`), detected by the
  release directory the launcher itself resolved — never by the working
  directory, so an installed `aiur` run from inside a clone still gets its
  notice and a dev launcher run from anywhere stays silent.
  """
  @spec dev_launcher?() :: boolean()
  def dev_launcher? do
    case System.get_env("AIUR_RELEASE_DIR") do
      dir when is_binary(dir) -> String.ends_with?(dir, "/src/_build/dev/rel/aiur")
      _ -> false
    end
  end

  @doc "The installed version: the CLI package version when the launcher set it, else the mix version."
  @spec installed_version() :: String.t()
  def installed_version do
    case System.get_env("AIUR_CLI_VERSION") do
      value when is_binary(value) and value != "" -> value
      _ -> to_string(Mix.Project.config()[:version])
    end
  end

  @doc """
  Resolve the user's channel from the installed version and the observed
  dist-tags: a `-nightly` prerelease is `:nightly`; a stable version that
  matches `next`, or sits strictly between `latest` and `next`, is `:next`;
  everything else is `:latest`. Never crosses channels for a comparison — a
  `next` user is never measured against `latest`.
  """
  @spec channel(String.t(), map()) :: :latest | :next | :nightly
  def channel(installed, dist_tags) do
    case Version.parse(installed) do
      {:ok, %{pre: ["nightly" | _]}} ->
        :nightly

      {:ok, _stable} ->
        stable_channel(installed, dist_tags)

      _ ->
        :latest
    end
  end

  # A stable install is `next` when it matches the `next` dist-tag or sits
  # strictly between `latest` and `next`; otherwise it is `latest`.
  defp stable_channel(installed, dist_tags) do
    if next_user?(installed, dist_tags), do: :next, else: :latest
  end

  defp next_user?(installed, dist_tags) do
    next = Map.get(dist_tags, "next")
    latest = Map.get(dist_tags, "latest")
    Map.get(dist_tags, "next") == installed or in_next_range?(installed, next, latest)
  end

  defp in_next_range?(installed, next, latest) do
    is_binary(next) and is_binary(latest) and Version.newer?(next, installed) and
      Version.newer?(installed, latest)
  end

  @doc """
  Compute the pending notice for an installed version against the registry
  dist-tags, honoring the version already told (`notified`). Returns
  `%Aiur.Upgrade.Notice{}` or `:none`.

  Never offers a downgrade, never compares across channels, and never repeats a
  version already announced.
  """
  @spec notice(String.t(), map(), String.t() | nil) :: Aiur.Upgrade.Notice.t() | :none
  def notice(installed, dist_tags, notified \\ nil) do
    ch = channel(installed, dist_tags)
    tag = channel_tag(ch)

    case Map.get(dist_tags, tag) do
      nil ->
        channel_gone_notice(installed, ch, dist_tags, notified)

      available ->
        cond do
          # Never present a lower version as an upgrade.
          not Version.newer?(available, installed) ->
            :none

          # Never nag: the same version was already announced.
          already_told?(notified, available) ->
            :none

          true ->
            %Aiur.Upgrade.Notice{
              installed: installed,
              available: available,
              channel: ch,
              command: upgrade_command(),
              text: notice_text(installed, available),
              channel_gone: false
            }
        end
    end
  end

  @doc "The exact command the notice tells the user to run."
  @spec upgrade_command() :: String.t()
  def upgrade_command, do: "aiur upgrade"

  @doc """
  Fire-and-forget check entrypoint (spawned at daemon boot, never awaited).
  Silently does nothing when disabled or under a dev launcher. Otherwise reads
  the cached state; a fresh cache surfaces the pending notice (no network) and
  a stale cache refreshes it from the registry. Logs the notice when one is
  pending; the launcher surfaces it to the operator.

  Accepts `:transport` and `:state_file` for tests.
  """
  @spec check_and_announce(keyword()) :: :ok
  def check_and_announce(opts \\ []) do
    transport = Keyword.get(opts, :transport, Registry.Transport.Req)
    state_file = Keyword.get(opts, :state_file)
    settings = Keyword.get(opts, :settings)

    cond do
      disabled?(settings) -> :ok
      dev_launcher?() -> :ok
      true -> run_check(transport, state_file)
    end
  rescue
    # Fail open and silent: a version check must never affect the run.
    _ -> :ok
  end

  @doc "Log the pending notice (the launcher prints it to the operator)."
  @spec announce(map()) :: :ok
  def announce(notice) when is_map(notice) do
    case Map.get(notice, :text) || Map.get(notice, "text") do
      text when is_binary(text) -> Logger.info("aiur_upgrade #{text}")
      _ -> :ok
    end

    :ok
  end

  defp run_check(transport, state_file) do
    state = read_state(state_file)
    notified_marker = notified_file(state_file)

    if cache_fresh?(state) do
      # Fresh cache: surface whatever a prior check computed, no network.
      announce_pending(state, State.read_notified(notified_marker))
      :ok
    else
      refresh_check(transport, state_file, state, notified_marker)
    end
  end

  defp read_state(state_file) do
    case State.read(state_file) do
      {:ok, parsed} -> parsed
      :error -> State.default()
    end
  end

  defp refresh_check(transport, state_file, state, notified_marker) do
    case Registry.fetch_dist_tags(transport) do
      {:ok, tags} ->
        notified = State.read_notified(notified_marker)
        pending = notice(installed_version(), tags, notified)
        updated = %{state | last_check_ms: now_ms(), dist_tags: tags, notice: notice_to_map(pending)}
        State.write(updated, state_file)
        if pending != :none, do: announce(pending)
        :ok

      {:error, _reason} ->
        # Fail open: stamp the check so an offline host does not retry on
        # every run, and keep any notice a prior successful check computed.
        updated = %{state | last_check_ms: now_ms()}
        State.write(updated, state_file)
        announce_pending(state, State.read_notified(notified_marker))
        :ok
    end
  end

  # The "last told" marker lives beside the state file, so tests that point at a
  # temp state file never touch the real marker.
  defp notified_file(nil), do: State.notified_path()
  defp notified_file(state_file), do: Path.join(Path.dirname(state_file), "upgrade-notified.txt")

  # Log a stored notice only while it is still newer than what the operator was
  # told — after the engine marks it as notified, a reboot should not re-nag.
  defp announce_pending(state, notified) do
    case state.notice do
      notice when is_map(notice) ->
        available = Map.get(notice, "available") || Map.get(notice, :available)

        if is_binary(available) and not already_told?(notified, available) do
          announce(notice)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp cache_fresh?(state) do
    case state.last_check_ms do
      ms when is_integer(ms) and ms > 0 -> now_ms() - ms < @check_interval_ms
      _ -> false
    end
  end

  defp already_told?(nil, _available), do: false

  defp already_told?(notified, available) do
    # A sentinel ("gone:<channel>") or junk never counts as "already told".
    match?({:ok, _}, Version.parse(notified)) and not Version.newer?(available, notified)
  end

  defp channel_gone_notice(installed, channel, dist_tags, notified) do
    latest = Map.get(dist_tags, "latest")

    cond do
      # A strictly-newer `latest` is a legitimate migration path.
      is_binary(latest) and Version.newer?(latest, installed) and
          not already_told?(notified, latest) ->
        %Aiur.Upgrade.Notice{
          installed: installed,
          available: latest,
          channel: :latest,
          command: upgrade_command(),
          text: channel_gone_migrate_text(installed, channel, latest),
          channel_gone: true
        }

      # Already told the user their channel is gone; do not nag.
      notified == @gone_prefix <> channel_tag(channel) ->
        :none

      true ->
        %Aiur.Upgrade.Notice{
          installed: installed,
          available: nil,
          channel: channel,
          command: nil,
          text: channel_gone_text(installed, channel),
          channel_gone: true
        }
    end
  end

  defp channel_tag(:latest), do: "latest"
  defp channel_tag(:next), do: "next"
  defp channel_tag(:nightly), do: "nightly"

  defp notice_to_map(:none), do: nil

  defp notice_to_map(%Aiur.Upgrade.Notice{} = notice) do
    %{
      "installed" => notice.installed,
      "available" => notice.available,
      "channel" => channel_tag(notice.channel),
      "command" => notice.command,
      "text" => notice.text,
      "channel_gone" => notice.channel_gone
    }
  end

  defp notice_text(installed, available) do
    "aiur: a new version is available — #{installed} → #{available}. Update with: aiur upgrade"
  end

  defp channel_gone_text(installed, channel) do
    "aiur: the #{channel} channel no longer publishes new versions (installed #{installed}). " <>
      "Run `aiur upgrade` to see what is available"
  end

  defp channel_gone_migrate_text(installed, channel, latest) do
    "aiur: the #{channel} channel no longer publishes; #{installed} → #{latest} is available. " <>
      "Update with: aiur upgrade"
  end

  defp env_disabled? do
    Enum.any?(["AIUR_UPGRADE_CHECK_DISABLED", "AIUR_NO_UPDATE_NOTIFIER"], fn key ->
      System.get_env(key) in ["1", "true"]
    end)
  end

  defp ci? do
    case System.get_env("CI") do
      value when is_binary(value) and value not in ["false", "0"] -> value != ""
      _ -> false
    end
  end

  defp now_ms, do: System.os_time(:millisecond)
end
