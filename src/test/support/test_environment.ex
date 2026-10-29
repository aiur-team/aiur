defmodule Aiur.TestEnvironment do
  @moduledoc false

  @contaminating_env_vars [
    "TMUX",
    "TMUX_PANE",
    "ERL_AFLAGS",
    "AIUR_DASHBOARD_USERNAME",
    "AIUR_DASHBOARD_PASSWORD",
    "AIUR_DEV_TEST_TICKET_IDS",
    "AIUR_DEV_TEST_STATE_DIR",
    "AIUR_DEBUG",
    "AIUR_SUPERVISOR_TOKEN",
    "AIUR_NODE",
    "AIUR_ERLANG_COOKIE",
    "AIUR_TMUX_CONF",
    "AIUR_TMUX_SESSION",
    "AIUR_TMUX_SOCKET",
    "AIUR_AGENT_TMUX_SOCKET",
    "AIUR_LOGS_ROOT"
  ]

  def clear_inherited!(only \\ @contaminating_env_vars) when is_list(only) do
    @contaminating_env_vars
    |> Enum.filter(&(&1 in only))
    |> Enum.each(&System.delete_env/1)

    :ok
  end
end
