defmodule Aiur.RtkStartupCheck do
  @moduledoc "Reports an unsafe host RTK hook once during daemon startup."

  require Logger

  alias Aiur.{Alerts, Rtk}

  @alert_topic "system.rtk.gh_rewrite"
  @remedy ~s(Add `exclude_commands = ["gh"]` under `[hooks]` in rtk's config.)

  @doc false
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    rtk_path = Keyword.get_lazy(opts, :rtk_path, fn -> System.find_executable("rtk") end)

    if is_binary(rtk_path) do
      check(rtk_path, opts)
    end

    :ok
  end

  defp check(rtk_path, opts) do
    result = Rtk.check_host_hook(Keyword.put(opts, :rtk_path, rtk_path))

    case result do
      {:rewrites_gh, _evidence} ->
        message = "The host rtk hook rewrites agent `gh` calls, bypassing Aiur's GitHub quota guard. #{@remedy}"

        Logger.warning(message)

        emit = Keyword.get(opts, :emit, &Alerts.emit_system/2)

        emit.(@alert_topic,
          message: message,
          reason: "The host rtk PreToolUse hook rewrites governed GitHub commands.",
          needs_attention: true,
          severity: "warning"
        )

      {:probe_failed, reason} ->
        Logger.warning("rtk host hook probe failed: #{inspect(reason)}")

      :ok ->
        :ok
    end
  rescue
    error -> Logger.warning("rtk host hook check failed: #{Exception.message(error)}")
  end
end
