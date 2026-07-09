defmodule Aiur.Workspace.BootstrapImage do
  @moduledoc "Bootstrap-image seeding: copy warm cache paths from a Docker image into an agent workspace via a shell script run locally or over SSH."

  require Logger
  alias Aiur.{Config}
  alias Aiur.Workspace.{Context, Hooks, Remote}

  @warm_cache_paths ["src/deps", "src/_build", "deps", "_build"]

  @spec maybe_seed(Path.t(), map(), String.t() | nil) :: :ok | {:error, term()}
  def maybe_seed(workspace, issue_context, worker_host) do
    case Config.workspace_bootstrap_image() do
      image when is_binary(image) ->
        seed_from_bootstrap_image(
          workspace,
          issue_context,
          image,
          Config.workspace_bootstrap_image_pull?(),
          worker_host
        )

      _ ->
        :ok
    end
  end

  @doc false
  @spec bootstrap_image_script(Path.t(), String.t(), boolean()) :: String.t()
  def bootstrap_image_script(workspace, image, pull?) do
    [
      "set -eu",
      Remote.remote_shell_assign("workspace", workspace),
      pull? && "docker pull #{Aiur.Shell.escape(image)}",
      "docker run --rm --user \"$(id -u):$(id -g)\" --volume \"$workspace:/workspace\" --workdir /workspace --entrypoint /bin/sh #{Aiur.Shell.escape(image)} -lc #{Aiur.Shell.escape(bootstrap_image_copy_script())}"
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  @doc false
  @spec bootstrap_image_copy_script() :: String.t()
  def bootstrap_image_copy_script do
    paths = Enum.map_join(@warm_cache_paths, " ", &Aiur.Shell.escape/1)

    """
    set -eu
    found=0
    for path in #{paths}; do
      source="/opt/aiur/$path"
      target="/workspace/$path"

      if [ -e "$target" ]; then
        found=1
        printf 'aiur warm bootstrap: keep existing %s\\n' "$path"
      elif [ -e "$source" ]; then
        found=1
        mkdir -p "$(dirname "$target")"
        cp -R "$source" "$target"
        printf 'aiur warm bootstrap: seeded %s\\n' "$path"
      else
        printf 'aiur warm bootstrap: missing %s in image\\n' "$source"
      fi
    done

    if [ "$found" -eq 0 ]; then
      printf 'aiur warm bootstrap: no cache paths found in image or workspace\\n' >&2
      exit 66
    fi
    """
  end

  defp seed_from_bootstrap_image(workspace, issue_context, image, pull?, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Seeding workspace from bootstrap image #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local image=#{image}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", bootstrap_image_script(workspace, image, pull?)],
          cd: workspace,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        Hooks.handle_hook_command_result(cmd_result, workspace, issue_context, "bootstrap_image")

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace bootstrap image timed out #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, "bootstrap_image", timeout_ms}}
    end
  end

  defp seed_from_bootstrap_image(workspace, issue_context, image, pull?, worker_host)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Seeding workspace from bootstrap image #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host} image=#{image}")

    case Remote.run_remote_command(worker_host, bootstrap_image_script(workspace, image, pull?), timeout_ms) do
      {:ok, cmd_result} ->
        Hooks.handle_hook_command_result(cmd_result, workspace, issue_context, "bootstrap_image")

      {:error, {:workspace_hook_timeout, "remote_command", ^timeout_ms}} ->
        {:error, {:workspace_hook_timeout, "bootstrap_image", timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
