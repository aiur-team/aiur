defmodule Aiur.PaneManager.Anchor do
  @moduledoc """
  Resolves PaneManager tmux anchors and publishes control metadata.
  """

  require Logger

  alias Aiur.Tmux

  @spec resolve_agent_list_pane(keyword(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def resolve_agent_list_pane(opts, tmux) do
    cond do
      pane = Keyword.get(opts, :agent_list_pane) ->
        {:ok, pane}

      pane = env_pane() ->
        {:ok, pane}

      true ->
        Tmux.resolve_self_pane(tmux)
    end
  end

  defp env_pane do
    case System.get_env("TMUX_PANE") do
      pane when is_binary(pane) and pane != "" -> pane
      _ -> nil
    end
  end

  @spec resolve_window_target(keyword(), GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_window_target(opts, tmux, agent_list_pane) do
    case Keyword.get(opts, :window_target) do
      target when is_binary(target) and target != "" -> {:ok, target}
      _ -> Tmux.window_for(tmux, agent_list_pane)
    end
  end

  # Publish the dashboard's bound base URL as a global tmux option so the
  # opencode Ctrl+C key binding (aiur.tmux.conf) can reach the control
  # endpoint. Best-effort: if the server isn't bound or the option can't
  # be set, the binding sees an empty value and degrades to a plain pane
  # close, which is the pre-bridge behaviour.
  @spec publish_control_url(GenServer.server()) :: :ok
  def publish_control_url(tmux) do
    with port when is_integer(port) and port > 0 <- Aiur.HttpServer.bound_port() do
      url = "http://#{control_url_host()}:#{port}"
      _ = Tmux.command(tmux, "set-option -g @aiur_control_url #{url}")
    end

    :ok
  rescue
    error ->
      Logger.warning("PaneManager: could not publish control url: #{inspect(error)}")
      :ok
  end

  defp control_url_host do
    case Aiur.Config.server_host() do
      host when host in ["0.0.0.0", "::", "", nil] -> "127.0.0.1"
      host when is_binary(host) -> host
    end
  end
end
