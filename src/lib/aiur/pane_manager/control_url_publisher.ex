defmodule Aiur.PaneManager.ControlUrlPublisher do
  @moduledoc """
  Keeps the dashboard's bound URL published in the launcher tmux server.

  The HTTP listener and tmux session have independent lifecycles. This worker
  reconciles them continuously so a late listener bind, endpoint restart, or
  transient tmux failure cannot leave dashboard discovery empty or stale.
  """

  use GenServer
  require Logger

  alias Aiur.{HttpServer, Tmux}
  alias Aiur.PaneManager.Anchor

  @default_retry_interval_ms 1_000
  @default_stable_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    state = %{
      tmux: Keyword.get(opts, :tmux, Tmux),
      url_fun: Keyword.get(opts, :url_fun, &HttpServer.base_url/0),
      publish_fun: Keyword.get(opts, :publish_fun, &Anchor.publish_control_url/2),
      unpublish_fun: Keyword.get(opts, :unpublish_fun, &Anchor.unpublish_control_url/1),
      retry_interval_ms: Keyword.get(opts, :interval_ms, @default_retry_interval_ms),
      stable_interval_ms: Keyword.get(opts, :stable_interval_ms, Keyword.get(opts, :interval_ms, @default_stable_interval_ms)),
      published_url: nil,
      tmux_reconciled?: false,
      last_failure: nil
    }

    send(self(), :reconcile_control_url)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile_control_url, state) do
    state = reconcile(state)
    Process.send_after(self(), :reconcile_control_url, next_interval(state))
    {:noreply, state}
  end

  defp next_interval(%{last_failure: failure, retry_interval_ms: interval}) when not is_nil(failure), do: interval
  defp next_interval(%{published_url: url, stable_interval_ms: interval}) when is_binary(url), do: interval
  defp next_interval(%{retry_interval_ms: interval}), do: interval

  defp reconcile(state) do
    case read_url(state.url_fun) do
      {:ok, url} when is_binary(url) and url != "" -> publish_url(state, url)
      {:ok, nil} -> clear_unbound_url(state)
      {:ok, invalid} -> reconciliation_failed(state, :discover, {:invalid_control_url, invalid})
      {:error, reason} -> reconciliation_failed(state, :discover, {:control_url_lookup_failed, reason})
    end
  end

  defp publish_url(state, url) do
    case invoke(state.publish_fun, [state.tmux, url]) do
      :ok ->
        if state.published_url != url or not is_nil(state.last_failure) do
          Logger.info("control_url_publisher action=publish outcome=completed reason=url_available retrying=false")
        end

        %{state | published_url: url, tmux_reconciled?: true, last_failure: nil}

      {:error, reason} ->
        reconciliation_failed(state, :publish, reason)
    end
  end

  defp clear_unbound_url(%{published_url: nil, tmux_reconciled?: true} = state), do: state

  defp clear_unbound_url(state) do
    case invoke(state.unpublish_fun, [state.tmux]) do
      :ok ->
        Logger.info(
          "control_url_publisher action=unpublish outcome=completed " <>
            "reason=dashboard_unbound retrying=true retry_interval_ms=#{state.retry_interval_ms}"
        )

        %{
          state
          | published_url: nil,
            tmux_reconciled?: true,
            last_failure: {:discover, :dashboard_unbound}
        }

      {:error, reason} ->
        reconciliation_failed(state, :unpublish, reason)
    end
  end

  defp reconciliation_failed(%{last_failure: {action, reason}} = state, action, reason), do: state

  defp reconciliation_failed(state, action, reason) do
    Logger.warning(
      "control_url_publisher action=#{action} outcome=failed reason=#{inspect(reason)} " <>
        "retrying=true retry_interval_ms=#{state.retry_interval_ms}"
    )

    %{state | last_failure: {action, reason}}
  end

  defp read_url(url_fun) do
    {:ok, url_fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke(fun, args) do
    apply(fun, args)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
