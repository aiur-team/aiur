defmodule Aiur.Codex.Frames do
  @moduledoc """
  Codex-specific request frame builders.
  """

  alias Aiur.Codex.DynamicTool

  @thread_start_id 2
  @turn_start_id 3
  @rate_limits_read_id 4

  @spec thread_start_id() :: 2
  def thread_start_id, do: @thread_start_id

  @spec turn_start_id() :: 3
  def turn_start_id, do: @turn_start_id

  @spec rate_limits_read_id() :: 4
  def rate_limits_read_id, do: @rate_limits_read_id

  @spec rate_limits_read_frame() :: map()
  def rate_limits_read_frame do
    %{
      "method" => "account/rateLimits/read",
      "id" => rate_limits_read_id(),
      "params" => nil
    }
  end

  @spec thread_init_frame(String.t() | nil, Path.t(), map()) :: map()
  def thread_init_frame(nil, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    %{
      "method" => "thread/start",
      "id" => thread_start_id(),
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    }
  end

  def thread_init_frame(resume_thread_id, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox})
      when is_binary(resume_thread_id) do
    %{
      "method" => "thread/resume",
      "id" => thread_start_id(),
      "params" => %{
        "threadId" => resume_thread_id,
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace
      }
    }
  end

  @spec turn_start_frame(String.t(), String.t(), map(), Path.t(), String.t() | map(), map()) :: map()
  def turn_start_frame(thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    %{
      "method" => "turn/start",
      "id" => turn_start_id(),
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    }
  end

  @spec operator_turn_frame(map(), integer(), String.t()) :: map()
  def operator_turn_frame(session, request_id, text) do
    %{
      "method" => "turn/start",
      "id" => request_id,
      "params" => %{
        "threadId" => session.thread_id,
        "input" => [%{"type" => "text", "text" => text}],
        "cwd" => session.workspace,
        "approvalPolicy" => Map.get(session, :approval_policy),
        "sandboxPolicy" => Map.get(session, :turn_sandbox_policy)
      }
    }
  end
end
