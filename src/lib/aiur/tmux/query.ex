defmodule Aiur.Tmux.Query do
  @moduledoc """
  Read-only tmux introspection helpers. Each function takes the exec context
  map as its first argument and returns a plain result tuple.
  """

  alias Aiur.Tmux.Exec

  @spec capture_pane(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def capture_pane(state, pane_id) do
    case Exec.run_args(state, ["capture-pane", "-p", "-t", pane_id]) do
      {:ok, lines} -> {:ok, lines}
      {:error, _} = err -> err
    end
  end

  @spec pane_pid(map(), String.t()) :: {:ok, integer()} | {:error, term()}
  def pane_pid(state, pane_id) do
    case Exec.run_args(state, ["display-message", "-p", "-t", pane_id, "\#{pane_pid}"]) do
      {:ok, [pid_str | _]} ->
        case Integer.parse(String.trim(pid_str)) do
          {pid, _} -> {:ok, pid}
          :error -> {:error, :no_pane_pid}
        end

      {:ok, []} ->
        {:error, :no_pane_pid}

      {:error, _} = err ->
        err
    end
  end

  @spec list_windows(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list_windows(state) do
    case Exec.run_args(state, ["list-windows", "-a", "-F", "\#{window_name}\t\#{pane_id}"]) do
      {:ok, lines} ->
        windows =
          lines
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&parse_window_line/1)

        {:ok, windows}

      {:error, _} = err ->
        err
    end
  end

  @spec list_panes(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_panes(state, window_target) do
    case Exec.run_args(state, ["list-panes", "-t", window_target, "-F", "\#{pane_id}"]) do
      {:ok, pane_ids} ->
        {:ok, Enum.map(pane_ids, &String.trim/1)}

      {:error, _} = err ->
        err
    end
  end

  @spec window_size(map(), String.t()) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, term()}
  def window_size(state, pane_id) do
    case Exec.run_args(state, [
           "display-message",
           "-p",
           "-t",
           pane_id,
           "\#{window_width}x\#{window_height}"
         ]) do
      {:ok, [dims | _]} ->
        parse_dims(dims)

      {:ok, []} ->
        {:error, :no_dims}

      {:error, _} = err ->
        err
    end
  end

  @spec window_for(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def window_for(state, pane_id) do
    case Exec.run_args(state, [
           "display-message",
           "-p",
           "-t",
           pane_id,
           "\#{session_name}:\#{window_index}"
         ]) do
      {:ok, [target | _]} -> {:ok, String.trim(target)}
      {:ok, []} -> {:error, :no_window}
      {:error, _} = err -> err
    end
  end

  @spec resolve_self_pane(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_self_pane(state) do
    env_pane = System.get_env("TMUX_PANE")

    # Refusing to start when this fails is preferable to silently losing
    # the anchor and watching every conversation pane fall back to the
    # legacy "split rightmost" path — that mode was the root cause of the
    # regression issue #34 tracks.
    if is_binary(env_pane) and env_pane != "" do
      case Exec.run_args(state, ["display-message", "-p", "-t", env_pane, "\#{pane_id}"]) do
        {:ok, [id | _]} ->
          {:ok, String.trim(id)}

        {:ok, []} ->
          {:error, :no_pane_id}

        {:error, _} = err ->
          err
      end
    else
      {:error, :no_tmux_pane_env}
    end
  end

  defp parse_window_line(line) do
    case String.split(line, "\t", parts: 2) do
      [name, pane_id] -> [{name, pane_id}]
      _ -> []
    end
  end

  defp parse_dims(text) do
    case String.split(String.trim(text), "x", parts: 2) do
      [w_str, h_str] ->
        with {w, ""} <- Integer.parse(w_str),
             {h, ""} <- Integer.parse(h_str),
             true <- w > 0 and h > 0 do
          {:ok, {w, h}}
        else
          _ -> {:error, {:bad_dims, text}}
        end

      _ ->
        {:error, {:bad_dims, text}}
    end
  end
end
