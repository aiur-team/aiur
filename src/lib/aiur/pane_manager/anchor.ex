defmodule Aiur.PaneManager.Anchor do
  @moduledoc """
  Resolves PaneManager tmux anchors.
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
end
