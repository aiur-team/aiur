defmodule Aiur.Init.LabelsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels
  alias Aiur.Init.Labels, as: InitLabels

  defp io(parent, answers) do
    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      input: fn label, default, _hint ->
        send(parent, {:input_label, label})
        Map.get(Map.get(answers, :input, %{}), label, default)
      end,
      select: fn label, _opts, default -> Map.get(Map.get(answers, :select, %{}), label, default) end,
      multiselect: fn label, _opts, defaults ->
        Map.get(Map.get(answers, :multiselect, %{}), label, defaults)
      end,
      confirm: fn label, default ->
        send(parent, {:confirm, label})
        Map.get(Map.get(answers, :confirm, %{}), label, default)
      end
    }
  end

  defp all_lifecycle_labels do
    Labels.state_labels("agent") ++ Labels.required_rate_limit_fallback_labels("agent")
  end

  test "all labels already present: prints created status, no create_labels call" do
    parent = self()
    lifecycle = all_lifecycle_labels()
    complexity = Labels.complexity_labels()
    model = Labels.model_labels(["claude"])
    all_existing = lifecycle ++ complexity ++ model ++ Labels.effort_labels()

    deps = %{
      list_labels: fn _tracker -> {:ok, all_existing} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, _labels ->
        send(parent, :create_called)
        :ok
      end
    }

    answers = %{confirm: %{"Create the complexity labels?" => false, "Create the model labels?" => false}}

    result = InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["claude"])
    assert result == :ok
    refute_received :create_called

    messages = for {:puts, msg} <- Process.info(self(), :messages) |> elem(1), do: msg
    assert Enum.any?(messages, fn m -> m =~ "created." end)
  end

  test "no existing labels: prompts Press Enter and calls create_labels" do
    parent = self()

    deps = %{
      list_labels: fn _tracker -> {:ok, []} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, _labels ->
        send(parent, :create_called)
        :ok
      end
    }

    answers = %{
      confirm: %{
        "Create the complexity labels?" => false,
        "Create the model labels?" => false
      }
    }

    InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["claude"])
    assert_received :create_called
    # Press Enter prompt goes through io.input, which sends {:input_label, ...}
    assert_received {:input_label, "Press Enter to create them"}
  end

  test "codex-only setup provisions fallback labels with the configured prefix" do
    parent = self()

    deps = %{
      list_labels: fn _tracker -> {:ok, []} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, labels ->
        send(parent, {:create_called, labels})
        :ok
      end
    }

    answers = %{
      confirm: %{
        "Create the complexity labels?" => false,
        "Create the model labels?" => false,
        "Create the effort labels?" => false
      }
    }

    tracker = %{kind: "github", repo: "o/r", label_prefix: "team"}
    assert :ok = InitLabels.setup_labels(io(parent, answers), deps, tracker, ["codex"])

    assert_received {:create_called, required}
    assert "team:todo" in required
    assert "team:rate-limit-fallback" in required
    assert "model:claude" in required
    refute Enum.any?(required, &String.starts_with?(&1, "agent:"))
    refute_received {:create_called, _optional}
  end

  test "create_labels error returns :error and shows gh fallback" do
    parent = self()

    deps = %{
      list_labels: fn _tracker -> {:ok, []} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, _labels ->
        {:error, "no scope"}
      end
    }

    answers = %{confirm: %{}}

    result = InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, [])
    assert result == :error

    messages = for {:puts, msg} <- Process.info(self(), :messages) |> elem(1), do: msg
    assert Enum.any?(messages, fn m -> m =~ "gh label create" end)
  end

  test "confirms complexity labels: create_labels called with complexity labels" do
    parent = self()
    lifecycle = all_lifecycle_labels()

    deps = %{
      list_labels: fn _tracker -> {:ok, lifecycle} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, labels ->
        send(parent, {:create_called, labels})
        :ok
      end
    }

    answers = %{
      confirm: %{
        "Create the complexity labels?" => true,
        "Create the model labels?" => false
      }
    }

    InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["claude"])
    assert_received {:create_called, created}
    assert Enum.all?(Labels.complexity_labels(), &(&1 in created))
  end

  test "confirms effort labels: create_labels called with effort labels" do
    parent = self()
    lifecycle = all_lifecycle_labels()

    deps = %{
      list_labels: fn _tracker -> {:ok, lifecycle ++ Labels.complexity_labels() ++ Labels.model_labels(["claude"])} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, labels ->
        send(parent, {:create_called, labels})
        :ok
      end
    }

    answers = %{
      confirm: %{
        "Create the complexity labels?" => false,
        "Create the model labels?" => false,
        "Create the effort labels?" => true
      }
    }

    InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["claude"])
    assert_received {:create_called, created}
    assert Enum.all?(Labels.effort_labels(), &(&1 in created))
  end

  describe "discovered model tags" do
    # These encode the ticket's core promise: a model released after this aiur
    # was built becomes an offer with no code change, and the offer is always
    # the operator's call.
    defp discovery_deps(parent, discovered, existing) do
      %{
        list_labels: fn _tracker -> {:ok, existing} end,
        discover_models: fn backend ->
          send(parent, {:discovered, backend})
          {:ok, discovered}
        end,
        create_labels: fn _tracker, labels ->
          send(parent, {:create_called, labels})
          :ok
        end
      }
    end

    defp decline_known_stages do
      %{
        confirm: %{
          "Create the complexity labels?" => false,
          "Create the model labels?" => false,
          "Create the effort labels?" => false,
          "Create the model:remote label?" => false
        }
      }
    end

    test "a model upstream that the registry lacks is offered, and created on confirmation" do
      parent = self()
      deps = discovery_deps(parent, ["gpt-5.6-sol", "gpt-9.9-nova"], all_lifecycle_labels())

      answers = put_in(decline_known_stages(), [:confirm, "Create the newly discovered model labels?"], true)

      assert :ok = InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["codex"])

      assert_received {:discovered, "codex"}
      assert_received {:create_called, created}
      assert created == ["model:codex-gpt-9.9-nova"]
    end

    test "declining the offer creates nothing" do
      parent = self()
      deps = discovery_deps(parent, ["gpt-9.9-nova"], all_lifecycle_labels())

      answers = put_in(decline_known_stages(), [:confirm, "Create the newly discovered model labels?"], false)

      assert :ok = InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["codex"])

      assert_received {:confirm, "Create the newly discovered model labels?"}
      refute_received {:create_called, _labels}
    end

    test "nothing is offered when the registry is already current" do
      parent = self()
      deps = discovery_deps(parent, ["gpt-5.6-sol", "sol"], all_lifecycle_labels())

      assert :ok = InitLabels.setup_labels(io(parent, decline_known_stages()), deps, %{kind: "github", repo: "o/r"}, ["codex"])

      refute_received {:confirm, "Create the newly discovered model labels?"}
      refute_received {:create_called, _labels}
    end

    test "nothing is offered when the tag already exists in the repo" do
      parent = self()
      existing = all_lifecycle_labels() ++ ["model:codex-gpt-9.9-nova"]
      deps = discovery_deps(parent, ["gpt-9.9-nova"], existing)

      assert :ok = InitLabels.setup_labels(io(parent, decline_known_stages()), deps, %{kind: "github", repo: "o/r"}, ["codex"])

      refute_received {:confirm, "Create the newly discovered model labels?"}
    end

    test "init still completes when discovery cannot answer" do
      parent = self()

      deps = %{
        list_labels: fn _tracker -> {:ok, all_lifecycle_labels()} end,
        discover_models: fn _backend -> {:error, {:cli_unavailable, "codex"}} end,
        create_labels: fn _tracker, labels ->
          send(parent, {:create_called, labels})
          :ok
        end
      }

      assert :ok = InitLabels.setup_labels(io(parent, decline_known_stages()), deps, %{kind: "github", repo: "o/r"}, ["codex"])

      refute_received {:confirm, "Create the newly discovered model labels?"}
      refute_received {:create_called, _labels}
    end

    test "backends sharing a CLI are probed once" do
      parent = self()
      deps = discovery_deps(parent, ["opus-9-9"], all_lifecycle_labels())

      answers = put_in(decline_known_stages(), [:confirm, "Create the newly discovered model labels?"], true)

      assert :ok =
               InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["claude", "claude-repl"])

      assert_received {:discovered, "claude"}
      refute_received {:discovered, "claude-repl"}

      # One probe, but the tag is still seeded for each backend that accepts it.
      assert_received {:create_called, created}
      assert "model:claude-opus-9-9" in created
      assert "model:claude-repl-opus-9-9" in created
    end
  end

  test "no alias_labels: remote stage skipped" do
    parent = self()
    lifecycle = all_lifecycle_labels()

    deps = %{
      list_labels: fn _tracker -> {:ok, lifecycle} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, _labels -> :ok end
    }

    answers = %{confirm: %{"Create the complexity labels?" => false, "Create the model labels?" => false}}

    # With no claude kind, alias_labels returns [] so remote stage is skipped
    InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, [])

    messages = for {:puts, msg} <- Process.info(self(), :messages) |> elem(1), do: msg
    refute Enum.any?(messages, fn m -> m =~ "model:remote" end)
  end
end
