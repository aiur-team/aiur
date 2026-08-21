defmodule Aiur.PaneManager.Anchor do
  @moduledoc """
  Resolves PaneManager tmux anchors and publishes control metadata.
  """

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

  @spec publish_control_url(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def publish_control_url(tmux, url) when is_binary(url) and url != "" do
    case Tmux.command(tmux, "set-option -g @aiur_control_url #{url}") do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unpublish_control_url(GenServer.server()) :: :ok | {:error, term()}
  def unpublish_control_url(tmux) do
    case Tmux.command(tmux, "set-option -gu @aiur_control_url") do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
