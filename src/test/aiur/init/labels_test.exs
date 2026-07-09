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
    Labels.state_labels("agent")
  end

  test "all labels already present: prints created status, no create_labels call" do
    parent = self()
    lifecycle = all_lifecycle_labels()
    complexity = Labels.complexity_labels()
    model = Labels.model_labels(["claude"])
    all_existing = lifecycle ++ complexity ++ model

    deps = %{
      list_labels: fn _tracker -> {:ok, all_existing} end,
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

  test "create_labels error returns :error and shows gh fallback" do
    parent = self()

    deps = %{
      list_labels: fn _tracker -> {:ok, []} end,
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

  test "no alias_labels: remote stage skipped" do
    parent = self()
    lifecycle = all_lifecycle_labels()

    deps = %{
      list_labels: fn _tracker -> {:ok, lifecycle} end,
      create_labels: fn _tracker, _labels -> :ok end
    }

    answers = %{confirm: %{"Create the complexity labels?" => false, "Create the model labels?" => false}}

    # With no claude kind, alias_labels returns [] so remote stage is skipped
    InitLabels.setup_labels(io(parent, answers), deps, %{kind: "github", repo: "o/r"}, [])

    messages = for {:puts, msg} <- Process.info(self(), :messages) |> elem(1), do: msg
    refute Enum.any?(messages, fn m -> m =~ "model:remote" end)
  end
end
