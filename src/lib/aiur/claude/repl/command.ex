defmodule Aiur.Claude.Repl.Command do
  @moduledoc """
  Pure spawn-plan policy: owns the `exec claude` command line, the `--resume`
  policy (clean-start fallback when the transcript is gone), and the RC hook
  `--settings` wiring for lifecycle-hook turn detection.
  """

  require Logger

  alias Aiur.AgentEnvironment
  alias Aiur.Claude.Config
  alias Aiur.Claude.HookSettings
  alias Aiur.Claude.RemoteControl

  # `exec` replaces the wrapping shell so the pane's top process IS `claude`,
  # which makes `pane_pid` the process graceful_kill must terminate.
  @spec build_command(
          Path.t(),
          String.t() | nil,
          String.t() | nil,
          boolean(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: String.t()
  def build_command(workspace, model, effort, rc?, rc_name, settings_path, resume_id, opts \\ []) do
    flags =
      ["claude"]
      |> append_if(rc?, ["--remote-control", shell_escape(rc_name)])
      |> append_if(is_binary(resume_id), ["--resume", shell_escape(resume_id || "")])
      |> Kernel.++(["--permission-mode", shell_escape(Config.permission_mode())])
      |> append_if(is_binary(model), ["--model", shell_escape(model || "")])
      |> append_if(is_binary(effort), ["--effort", shell_escape(effort || "")])
      |> append_if(is_binary(settings_path), ["--settings", shell_escape(settings_path || "")])
      |> Enum.join(" ")

    environment =
      workspace
      |> AgentEnvironment.workspace_env_export_prefix(
        opts
        |> Keyword.take([:base_branch])
        |> Keyword.put(:build_gate, true)
      )

    ["cd #{shell_escape(workspace)}", environment, "exec #{flags}"]
    |> Enum.join(" && ")
  end

  # The claude session id to `--resume` on this spawn, or nil for a clean start.
  #
  # Resume only when the runner handed us a persisted handle id (resolved from
  # the per-issue `.session.json`, gated on a resumable backend + local worker)
  # AND that session's transcript jsonl still exists on disk. A missing handle
  # (first dispatch, or cleared on terminal state) or a vanished transcript
  # (workspace recloned without the host-local jsonl) degrades to a clean start
  # — the same graceful fallback the codex resume path takes (#378/#613).
  @doc false
  @spec resume_session_id(keyword(), Path.t()) :: String.t() | nil
  def resume_session_id(opts, workspace) do
    case Keyword.get(opts, :resume_thread_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        path =
          RemoteControl.session_transcript_path(workspace, session_id, projects_dir: Keyword.get(opts, :projects_dir))

        if File.exists?(path), do: session_id, else: nil

      _ ->
        nil
    end
  end

  # Write the lifecycle-hook settings file for an RC session. Returns the path, or
  # nil (no hooks wired) when not RC, when the identifier is unknown, or when the
  # dashboard URL / file write is unavailable — turn detection then falls back to
  # the legacy transcript path rather than failing the spawn.
  @spec maybe_hook_settings(boolean(), String.t() | nil) :: String.t() | nil
  def maybe_hook_settings(true, identifier) when is_binary(identifier) do
    case HookSettings.dashboard_url() do
      url when is_binary(url) ->
        case HookSettings.write(identifier, url) do
          {:ok, path} ->
            Logger.info("claude_repl hook_settings identifier=#{identifier} path=#{path}")
            path

          {:error, reason} ->
            Logger.warning("claude_repl hook_settings_failed identifier=#{identifier} reason=#{inspect(reason)}")

            nil
        end

      _ ->
        Logger.warning("claude_repl hook_settings_skipped identifier=#{identifier} reason=no_dashboard_url")

        nil
    end
  end

  def maybe_hook_settings(_rc?, _identifier), do: nil

  defp append_if(list, true, extra), do: list ++ extra
  defp append_if(list, false, _extra), do: list
  defp append_if(list, nil, _extra), do: list

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
