defmodule Aiur.Tmux.Input do
  @moduledoc """
  Keystroke and paste delivery to tmux panes. Each function takes the exec
  context map as its first argument and returns a plain result tuple.
  """

  alias Aiur.Tmux.Exec

  @spec send_keys_literal(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys_literal(state, pane_id, text) do
    case Exec.run_args(state, ["send-keys", "-t", pane_id, "-l", text]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec paste_text(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def paste_text(state, pane_id, text) do
    paste_via_buffer(state, pane_id, text)
  end

  @spec send_enter(map(), String.t()) :: :ok | {:error, term()}
  def send_enter(state, pane_id) do
    case Exec.run_args(state, ["send-keys", "-t", pane_id, "Enter"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec clear_input(map(), String.t()) :: :ok | {:error, term()}
  def clear_input(state, pane_id) do
    case Exec.run_args(state, ["send-keys", "-t", pane_id, "C-u"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec send_interrupt(map(), String.t()) :: :ok | {:error, term()}
  def send_interrupt(state, pane_id) do
    case Exec.run_args(state, ["send-keys", "-t", pane_id, "C-c"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec send_escape(map(), String.t()) :: :ok | {:error, term()}
  def send_escape(state, pane_id) do
    case Exec.run_args(state, ["send-keys", "-t", pane_id, "Escape"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Inject text via a tmux paste buffer so delivery isn't capped by tmux's
  # ~16KB `send-keys` command-length limit. `load-buffer` reads the text from
  # a temp file (keeping it off the command line entirely); `paste-buffer -p -d`
  # pastes it into the pane (with bracketed-paste markers) and drops the buffer.
  # The buffer name is unique so concurrent panes never clobber each other's
  # pending paste.
  #
  # `-p` is load-bearing: it wraps the paste in bracketed-paste control codes so
  # a TUI that requested bracketed paste (the interactive `claude` REPL,
  # opencode) collapses a multi-line paste into a single `[Pasted text]` chip.
  # Without it the buffer arrives as raw newlines; claude renders the prompt
  # expanded and a single `Enter` inserts a newline instead of submitting, so an
  # RC turn's prompt is pasted but never sent (the turn never starts).
  defp paste_via_buffer(state, pane_id, text) do
    buffer = "aiur-paste-#{System.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), buffer)

    try do
      with :ok <- File.write(tmp, text),
           {:ok, _} <- Exec.run_args(state, ["load-buffer", "-b", buffer, tmp]),
           {:ok, _} <- Exec.run_args(state, ["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane_id]) do
        :ok
      else
        {:error, _} = err -> err
      end
    after
      File.rm(tmp)
    end
  end
end
