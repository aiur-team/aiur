defmodule Aiur.Orchestrator.TrackerHealthPreflightTest do
  # The poll cycle's own path. Without this, every orchestrator test installs a
  # stub client that exports only `preflight_auth/0`, so `ensure_auth_preflight/0`
  # always takes its fallback branch and nothing proves the memoized path is the
  # one the cycle actually uses.
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{State, TrackerHealth}

  defmodule MemoizingClient do
    @moduledoc false

    @spec preflight_auth() :: :ok | {:error, term()}
    def preflight_auth, do: record(:full)

    @spec ensure_preflight() :: :ok | {:error, term()}
    def ensure_preflight do
      case :persistent_term.get({__MODULE__, :proven?}, false) do
        true ->
          record(:memoized)

        false ->
          :persistent_term.put({__MODULE__, :proven?}, true)
          record(:full)
      end
    end

    @spec reset() :: :ok
    def reset do
      :persistent_term.erase({__MODULE__, :proven?})
      :persistent_term.put({__MODULE__, :calls}, [])
      :ok
    end

    @spec calls() :: [atom()]
    def calls, do: :persistent_term.get({__MODULE__, :calls}, []) |> Enum.reverse()

    defp record(kind) do
      :persistent_term.put({__MODULE__, :calls}, [kind | :persistent_term.get({__MODULE__, :calls}, [])])
      :ok
    end
  end

  defmodule FullOnlyClient do
    @moduledoc false

    @spec preflight_auth() :: :ok
    def preflight_auth, do: :ok
  end

  setup do
    previous = Application.get_env(:aiur, :github_client_module)
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "tracker-health-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    MemoizingClient.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous do
        nil -> Application.delete_env(:aiur, :github_client_module)
        module -> Application.put_env(:aiur, :github_client_module, module)
      end
    end)

    :ok
  end

  test "the poll cycle prefers the memoized preflight and spends nothing on the second cycle" do
    Application.put_env(:aiur, :github_client_module, MemoizingClient)
    state = %State{}

    for _cycle <- 1..6 do
      assert {:ok, ^state} = TrackerHealth.ensure_tracker_preflight(state)
    end

    # Six cycles is one idle hour. One full check, five answered from memory —
    # and never the unmemoized `preflight_auth/0`.
    assert MemoizingClient.calls() == [:full, :memoized, :memoized, :memoized, :memoized, :memoized]
  end

  test "a client without the memoized entry point still gets the full check" do
    Application.put_env(:aiur, :github_client_module, FullOnlyClient)
    state = %State{}

    assert {:ok, ^state} = TrackerHealth.ensure_tracker_preflight(state)
  end
end
