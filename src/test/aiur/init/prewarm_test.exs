defmodule Aiur.Init.PrewarmTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Prewarm

  test "prompt_prewarm disables global configs" do
    assert Prewarm.prompt_prewarm(io(self()), deps(), :global) == %{enabled: false, base_build: nil}
  end

  test "detected toolchain can be accepted" do
    deps =
      deps(%{
        detect_toolchain: fn -> {:ok, %{language: :elixir, build_root: "src", command: "mise exec -- mix compile"}} end
      })

    io = io(self(), select: %{"Use this base build command?" => "use"})

    assert Prewarm.prompt_prewarm(io, deps, :repo_local) == %{
             enabled: true,
             base_build: "mise exec -- mix compile"
           }
  end

  test "detection miss and ambiguity disclose fallback prompt and disable prewarm" do
    assert Prewarm.prompt_prewarm(io(self()), deps(%{detect_toolchain: fn -> :none end}), :repo_local) == %{
             enabled: false,
             base_build: nil
           }

    log = puts_log()
    assert log =~ "Couldn't auto-detect"
    assert log =~ "called the warm base"

    ambiguous = [%{language: :elixir, build_root: "src"}, %{language: :node, build_root: "web"}]

    assert Prewarm.prompt_prewarm(
             io(self()),
             deps(%{detect_toolchain: fn -> {:ambiguous, ambiguous} end}),
             :repo_local
           ) == %{enabled: false, base_build: nil}

    log = puts_log()
    assert log =~ "Found multiple build roots"
    assert log =~ "called the warm base"
  end

  test "maybe_first_prewarm reports success and failure" do
    ok_deps =
      deps(%{
        prewarm_build: fn url, cmd ->
          send(self(), {:build, url, cmd})
          {:ok, "/base"}
        end
      })

    assert :ok =
             Prewarm.maybe_first_prewarm(
               io(self()),
               ok_deps,
               %{repo: "owner/repo"},
               %{enabled: true, base_build: "mise exec -- mix compile"}
             )

    assert_received {:build, "https://github.com/owner/repo.git", "mise exec -- mix compile"}
    assert puts_log() =~ "✅ Warm base ready."

    failing_deps = deps(%{prewarm_build: fn _url, _cmd -> {:error, {:base_build_failed, 1, "boom"}} end})

    assert :ok =
             Prewarm.maybe_first_prewarm(
               io(self()),
               failing_deps,
               %{repo: "owner/repo"},
               %{enabled: true, base_build: "bad"}
             )

    assert puts_log() =~ "Warm base build failed"
  end

  test "prewarm_section_yaml renders accepted and declined answers as valid YAML" do
    accepted = Prewarm.prewarm_section_yaml(%{enabled: true}) |> IO.iodata_to_binary()
    declined = Prewarm.prewarm_section_yaml(%{enabled: false}) |> IO.iodata_to_binary()

    assert {:ok, %{"prewarm" => %{"enabled" => true, "base_build_file" => "prewarm", "poll_seconds" => 0}}} =
             YamlElixir.read_from_string(accepted)

    assert {:ok, %{"prewarm" => %{"enabled" => false}}} = YamlElixir.read_from_string(declined)
  end

  defp io(parent, answers \\ []) do
    answers = Map.new(answers)

    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      input: fn label, default, _hint -> Map.get(Map.get(answers, :input, %{}), label, default) end,
      select: fn label, _opts, default -> Map.get(Map.get(answers, :select, %{}), label, default) end,
      confirm: fn label, default -> Map.get(Map.get(answers, :confirm, %{}), label, default) end
    }
  end

  defp deps(overrides \\ %{}) do
    Map.merge(
      %{
        detect_toolchain: fn -> :none end,
        prewarm_build: fn _url, _cmd -> {:ok, "/base"} end,
        ensure_prewarm_file: fn target, _cmd -> {:created, Path.join(Path.dirname(target), "prewarm")} end
      },
      overrides
    )
  end

  defp puts_log(acc \\ []) do
    receive do
      {:puts, msg} -> puts_log([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
