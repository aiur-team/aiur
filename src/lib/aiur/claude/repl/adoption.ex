defmodule Aiur.Claude.Repl.Adoption do
  @moduledoc false

  alias Aiur.Claude.Repl.Reaper
  alias Aiur.{ProcessReaper, Tmux}
  alias Aiur.Tmux.Socket

  @spec socket_name(map()) :: String.t() | nil
  def socket_name(session), do: Socket.name(session.tmux)

  @spec rebind(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def rebind(session, socket) do
    tmux = if socket, do: {:socket, Tmux, socket}, else: Tmux
    session = Map.put(session, :tmux, tmux)
    pane = session.pane_id

    with true <- Regex.match?(~r/^%\d+$/, pane),
         {:ok, _} <- Tmux.command(tmux, "rename-window -t #{pane} #{Reaper.default_repl_name()}") do
      ProcessReaper.register(:agent, Socket.pane_ref(tmux, pane))
      if session[:os_pid], do: ProcessReaper.register(:agent, {:os_pid, session.os_pid}, comm: "claude")
      {:ok, session}
    else
      false -> {:error, :invalid_pane}
      {:error, _} = error -> error
    end
  end
end
