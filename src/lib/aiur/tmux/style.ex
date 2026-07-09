defmodule Aiur.Tmux.Style do
  @moduledoc """
  Pane decoration, including the secret-safe border path. The border text
  carries the RC capability-token URL and must only ever flow through
  `Exec.run_args_silent/2` — never through a path that logs command arguments.
  """

  alias Aiur.Tmux.Exec

  @spec set_pane_border(map(), String.t(), nil | String.t()) :: :ok
  def set_pane_border(state, pane_id, nil) do
    _ = Exec.run_args_silent(state, ["set-option", "-pu", "-t", pane_id, "pane-border-status"])
    _ = Exec.run_args_silent(state, ["set-option", "-pu", "-t", pane_id, "pane-border-format"])
    :ok
  end

  def set_pane_border(state, pane_id, text) when is_binary(text) do
    _ = Exec.run_args_silent(state, ["set-option", "-p", "-t", pane_id, "pane-border-status", "top"])
    _ = Exec.run_args_silent(state, ["set-option", "-p", "-t", pane_id, "pane-border-format", text])
    :ok
  end

  @spec set_pane_title(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_pane_title(state, pane_id, title) do
    case Exec.run_args(state, ["select-pane", "-t", pane_id, "-T", title]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
