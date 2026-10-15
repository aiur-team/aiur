defmodule Aiur.Events.SourcePolicyTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher, SourcePolicy}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Workflow

  defmodule FakePolicy do
    @behaviour SourcePolicy

    @impl true
    def self_authored?(_topic, actor, _payload) do
      record({:self_authored, actor})
      actor == "bot"
    end

    @impl true
    def already_processed?(_opts) do
      record(:already_processed)
      Process.get(:policy_processed, false)
    end

    @impl true
    def observe(outcome, _opts) do
      record({:observe, outcome})
      :ok
    end

    @impl true
    def mark_processed(opts) do
      {:messages, messages} = Process.info(self(), :messages)
      # Background publishers share the app-env policy but have no test-only topic.
      topic = Keyword.get(opts, :test_topic)
      delivered = Enum.any?(messages, &match?({:event, %{topic: ^topic}}, &1))
      record({:mark_processed, delivered})
      :ok
    end

    defp record(call), do: Process.put(:policy_calls, Process.get(:policy_calls, []) ++ [call])
  end

  setup do
    prior = Application.fetch_env(:aiur, SourcePolicy)
    tracked = :persistent_term.get({Publisher, :tracked_fn}, nil)
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    Publisher.set_tracked_fn(fn _ -> true end)
    Application.put_env(:aiur, SourcePolicy, FakePolicy)
    topic = "ticket.#{System.unique_integer([:positive])}.issue.commented"
    :ok = Exchange.subscribe(topic)

    on_exit(fn ->
      case prior do
        {:ok, policy} -> Application.put_env(:aiur, SourcePolicy, policy)
        :error -> Application.delete_env(:aiur, SourcePolicy)
      end

      if tracked, do: :persistent_term.put({Publisher, :tracked_fn}, tracked), else: :persistent_term.erase({Publisher, :tracked_fn})
      restore_env("GITHUB_TOKEN", token)
    end)

    %{topic: topic, opts: [test_topic: topic]}
  end

  test "the configured policy decides self-authored filtering", %{topic: topic, opts: opts} do
    assert :filtered = Publisher.publish(topic, %{}, Keyword.put(opts, :actor, "bot"))
    assert Process.get(:policy_calls) == [{:self_authored, "bot"}, {:observe, :filtered}]
    refute_received {:event, %{topic: ^topic}}
  end

  test "already_processed runs before the dedup window and the window is evaluated once", %{topic: topic, opts: opts} do
    key = {"owner/repo", "comment", Integer.to_string(System.unique_integer([:positive]))}
    opts = Keyword.put(opts, :dedup_key, key)
    Process.put(:policy_processed, true)
    assert :deduped = Publisher.publish(topic, %{}, opts)
    assert Process.get(:policy_calls) == [{:self_authored, nil}, :already_processed, {:observe, :deduped}]

    Process.put(:policy_processed, false)
    Process.put(:policy_calls, [])
    assert {:ok, id, _} = Publisher.publish(topic, %{}, opts)
    assert_received {:event, %{id: ^id, topic: ^topic}}
    assert Process.get(:policy_calls) == [{:self_authored, nil}, :already_processed, {:observe, nil}, {:mark_processed, true}]
    assert :deduped = Publisher.publish(topic, %{}, opts)
  end

  test "mark_processed runs after fan-out", %{topic: topic, opts: opts} do
    assert {:ok, id, _} = Publisher.publish(topic, %{}, opts)
    assert Process.get(:policy_calls) == [{:self_authored, nil}, :already_processed, {:observe, nil}, {:mark_processed, true}]
    assert_received {:event, %{id: ^id, topic: ^topic}}
  end

  test "Null policy publishes with no GitHub filtering", %{topic: topic, opts: opts} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_bot_account: "aiur-bot")
    assert GitHubConfig.daemon_account() == "aiur-bot"
    Application.put_env(:aiur, SourcePolicy, SourcePolicy.Null)
    assert {:ok, id, _} = Publisher.publish(topic, %{}, Keyword.put(opts, :actor, "aiur-bot"))
    assert_received {:event, %{id: ^id, topic: ^topic}}
  end

  test "an absent policy uses Null", %{topic: topic, opts: opts} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_bot_account: "aiur-bot")
    assert GitHubConfig.daemon_account() == "aiur-bot"
    Application.delete_env(:aiur, SourcePolicy)
    assert {:ok, id, _} = Publisher.publish(topic, %{}, Keyword.put(opts, :actor, "aiur-bot"))
    assert_received {:event, %{id: ^id, topic: ^topic}}
  end

  test "a broken policy fails loudly", %{topic: topic} do
    Application.put_env(:aiur, SourcePolicy, __MODULE__.Missing)
    assert_raise UndefinedFunctionError, fn -> Publisher.publish(topic, %{}) end
  end

  test "namespace gates precede the policy and observation receives errors" do
    assert {:error, :decision_requires_durable_publish} = Publisher.publish("ticket.1.agent.decision.requested", %{}, actor: "bot")
    assert Process.get(:policy_calls) == [{:observe, {:error, :decision_requires_durable_publish}}]
    Process.put(:policy_calls, [])
    assert {:error, :executor_namespace_rejects_github_source} = Publisher.publish("executor.test", %{source: :github}, actor: "bot")
    assert Process.get(:policy_calls) == [{:observe, {:error, :executor_namespace_rejects_github_source}}]
  end

  test "tracked filtering precedes resource dedup and observation still runs", %{topic: topic} do
    Publisher.set_tracked_fn(fn _ -> false end)
    Process.put(:policy_processed, true)
    assert :filtered = Publisher.publish(topic, %{}, issue_number: "untracked")
    assert Process.get(:policy_calls) == [{:self_authored, nil}, {:observe, :filtered}]
  end

  # Future-regression guard: the required option contract already existed before this extraction.
  test "resource_source remains required before policy evaluation", %{topic: topic} do
    assert_raise KeyError, fn -> Publisher.publish(topic, %{}, resource: {:comment, "owner", "repo", 9}) end
    assert Process.get(:policy_calls, []) == []
  end
end
