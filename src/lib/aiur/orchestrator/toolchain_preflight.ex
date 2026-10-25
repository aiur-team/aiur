defmodule Aiur.Orchestrator.ToolchainPreflight do
  @moduledoc """
  Dispatch preflight for the host's mise-managed Erlang (#4692).

  When the pinned Erlang install vanishes, every worker's `mise exec -- mix`
  fails with `erl is not a valid shim`. This check holds dispatch and raises one
  attention instead of letting each dispatched worker fail on its own.

  It holds only on positive evidence: a host without mise, a directory whose
  mise config pins no Erlang, or a `mise` call that fails all pass.
  """

  alias Aiur.AlertFeed
  alias Aiur.Alerts

  @alert "system.toolchain.erlang_missing"

  @type runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec alert_name() :: String.t()
  def alert_name, do: @alert

  @doc """
  Returns `:ok`, or `{:error, {:toolchain_missing, detail}}` after raising the
  attention once. A passing check resolves an attention left by a failing one.
  """
  @spec check(keyword()) :: :ok | {:error, {:toolchain_missing, String.t()}}
  def check(opts \\ []) do
    case missing_erlang(opts) do
      nil ->
        resolve_attention()

      detail ->
        raise_attention(detail)
        {:error, {:toolchain_missing, detail}}
    end
  end

  defp missing_erlang(opts) do
    opts = Keyword.merge(Application.get_env(:aiur, :toolchain_preflight_opts, []), opts)
    mise = Keyword.get_lazy(opts, :mise, fn -> System.find_executable("mise") end)
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)

    with mise when is_binary(mise) <- mise,
         {output, 0} <- runner.(mise, ["ls", "--current", "--json", "erlang"], cd: dir),
         {:ok, [_ | _] = entries} <- Jason.decode(output),
         %{} = entry <- Enum.find(entries, &(&1["installed"] == false)) do
      "erlang #{entry["version"]} (requested #{entry["requested_version"]}) is missing from #{entry["install_path"]}; run `mise install` in #{dir}"
    else
      _ -> nil
    end
  end

  defp raise_attention(detail) do
    unless AlertFeed.active_system_attention?(@alert) do
      Alerts.emit_system(@alert,
        message: "Host Erlang install is missing; fleet dispatch is held.",
        reason: "Host Erlang install is missing; fleet dispatch is held. #{detail}",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  defp resolve_attention do
    if AlertFeed.active_system_attention?(@alert) do
      Alerts.emit_system(@alert <> ".resolved",
        message: "Host Erlang install is back.",
        reason: "Host Erlang install is back; fleet dispatch may resume.",
        needs_attention: false,
        severity: "info"
      )
    end

    :ok
  end
end
