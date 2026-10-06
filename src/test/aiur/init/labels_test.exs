defmodule Aiur.Init.LabelsTest do
  use ExUnit.Case, async: true

  defmodule CodingAgentFamily do
    @moduledoc false
    def of(backend), do: Aiur.CodingAgent.family_for(backend) || backend
  end

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

  test "setup provisions the configured rate-limit fallback label" do
    parent = self()

    deps = %{
      list_labels: fn _tracker -> {:ok, []} end,
      discover_models: fn _backend -> {:error, :offline} end,
      create_labels: fn _tracker, labels ->
        send(parent, {:create_called, labels})
        :ok
      end
    }

    answers = %{confirm: %{"Create the complexity labels?" => false, "Create the model labels?" => false, "Create the effort labels?" => false}}

    assert :ok = InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, ["claude"], {"claude", "codex"})

    assert_received {:create_called, required}
    assert "model:codex" in required
    refute "model:claude-repl" in required
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

  describe "model tags come from the installed CLIs" do
    # The ticket's core promise: a family released after this aiur was built is
    # offered with no code change, no version tag is ever offered, and tags
    # already in the repo are never touched.
    defp discovery_deps(parent, discovered, existing) do
      %{
        list_labels: fn _tracker -> {:ok, existing} end,
        discover_models: fn backend ->
          send(parent, {:discovered, backend})
          {:ok, Map.fetch!(discovered, CodingAgentFamily.of(backend))}
        end,
        create_labels: fn _tracker, labels ->
          send(parent, {:create_called, labels})
          :ok
        end,
        delete_labels: fn _tracker, labels -> send(parent, {:delete_called, labels}) end
      }
    end

    defp accept_model_stage_only do
      %{
        confirm: %{
          "Create the complexity labels?" => false,
          "Create the model labels?" => true,
          "Create the effort labels?" => false,
          "Create the model:remote label?" => false
        }
      }
    end

    @discovered %{
      "claude" => ["opus", "sonnet", "default", "opus-5-5"],
      "codex" => ["gpt-5.7-astra", "gpt-5.6-sol"]
    }

    test "offers the backends and the families the CLIs report — including new ones — and no versions" do
      parent = self()
      deps = discovery_deps(parent, @discovered, all_lifecycle_labels())

      assert :ok =
               InitLabels.setup_labels(io(parent, accept_model_stage_only()), deps, %{kind: "github", repo: "o/r"}, ["claude", "codex"])

      assert_received {:create_called, created}

      # `model:claude` is already a required rate-limit-fallback label, so it is
      # offered but not re-created.
      offered = ~w(model:claude model:codex model:opus model:sonnet model:astra model:sol)
      assert Enum.sort(created) == Enum.sort(offered -- all_lifecycle_labels())
    end

    test "the effort and remote stages are still offered alongside the family tags" do
      parent = self()
      deps = discovery_deps(parent, @discovered, all_lifecycle_labels())

      InitLabels.setup_labels(io(parent, accept_model_stage_only()), deps, %{kind: "github", repo: "o/r"}, ["claude", "codex"])

      assert_received {:confirm, "Create the effort labels?"}
      assert_received {:confirm, "Create the model:remote label?"}
    end

    test "an existing version tag is left in place and nothing is deleted" do
      parent = self()
      existing = all_lifecycle_labels() ++ ["model:claude-opus-4-8"]
      deps = discovery_deps(parent, @discovered, existing)

      InitLabels.setup_labels(io(parent, accept_model_stage_only()), deps, %{kind: "github", repo: "o/r"}, ["claude", "codex"])

      assert_received {:create_called, created}
      refute "model:claude-opus-4-8" in created
      refute_received {:delete_called, _labels}
    end

    test "when a CLI cannot answer, its registry families stand in and init completes" do
      parent = self()

      deps = %{
        list_labels: fn _tracker -> {:ok, all_lifecycle_labels()} end,
        discover_models: fn _backend -> {:error, {:cli_unavailable, "codex"}} end,
        create_labels: fn _tracker, labels ->
          send(parent, {:create_called, labels})
          :ok
        end
      }

      assert :ok =
               InitLabels.setup_labels(io(parent, accept_model_stage_only()), deps, %{kind: "github", repo: "o/r"}, ["codex"])

      assert_received {:create_called, created}
      assert "model:sol" in created
      refute Enum.any?(created, &(&1 =~ ~r/\d/))
    end

    test "backends sharing a CLI are probed once" do
      parent = self()
      deps = discovery_deps(parent, @discovered, all_lifecycle_labels())

      InitLabels.setup_labels(io(parent, accept_model_stage_only()), deps, %{kind: "github", repo: "o/r"}, ["claude", "claude-repl"])

      assert_received {:discovered, "claude"}
      refute_received {:discovered, "claude-repl"}
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
