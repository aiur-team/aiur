defmodule Aiur.Init.PromptTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Prompt

  # A reader fn that pops 1-byte binaries from a flattened key script and
  # returns :eof once exhausted.
  defp keys_reader(byte_lists) do
    {:ok, agent} = Agent.start_link(fn -> List.flatten(byte_lists) end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {:eof, []}
        [h | t] -> {h, t}
      end)
    end
  end

  defp up, do: ["\e", "[", "A"]
  defp down, do: ["\e", "[", "B"]
  defp enter, do: ["\r"]
  defp space, do: [" "]
  defp backspace, do: [<<127>>]
  defp chars(str), do: for(<<c <- str>>, do: <<c>>)

  defp noop_writer, do: fn _ -> :ok end

  defp base(reader), do: [raw?: false, writer: noop_writer(), reader: reader]

  describe "select/4 (radio)" do
    test "↓ ↓ Enter returns the third option" do
      reader = keys_reader([down(), down(), enter()])
      assert Prompt.select("Pick", ["a", "b", "c"], "a", base(reader)) == "c"
    end

    test "starts the cursor on the default option" do
      reader = keys_reader([enter()])
      assert Prompt.select("Pick", ["a", "b", "c"], "b", base(reader)) == "b"
    end

    test "↑ clamps at the top, ↓ clamps at the bottom" do
      top = keys_reader([up(), up(), enter()])
      assert Prompt.select("Pick", ["a", "b", "c"], "a", base(top)) == "a"

      bottom = keys_reader([down(), down(), down(), down(), enter()])
      assert Prompt.select("Pick", ["a", "b", "c"], "a", base(bottom)) == "c"
    end

    test ":eof mid-prompt resolves to the current cursor without crashing" do
      reader = keys_reader([down()])
      assert Prompt.select("Pick", ["a", "b", "c"], "a", base(reader)) == "b"
    end

    test "writer receives the rendered option list" do
      parent = self()
      writer = fn data -> send(parent, {:drawn, IO.iodata_to_binary(data)}) end
      reader = keys_reader([enter()])

      assert Prompt.select("Pick", ["alpha", "beta"], "alpha", raw?: false, writer: writer, reader: reader) ==
               "alpha"

      drawn = drain_drawn()
      assert drawn =~ "alpha"
      assert drawn =~ "beta"
      assert drawn =~ "❯"
    end
  end

  describe "multiselect/4" do
    test "Space ↓ Space Enter returns the two toggled values in option order" do
      reader = keys_reader([space(), down(), space(), enter()])
      assert Prompt.multiselect("Agents", ["claude", "codex", "amp"], [], base(reader)) == ["claude", "codex"]
    end

    test "pre-checks the defaults and toggling off removes them" do
      # cursor starts on "claude" (checked by default); Space unchecks it.
      reader = keys_reader([space(), enter()])
      assert Prompt.multiselect("Agents", ["claude", "codex"], ["claude"], base(reader)) == []
    end

    test "Enter with no toggles returns the defaults" do
      reader = keys_reader([enter()])
      assert Prompt.multiselect("Agents", ["claude", "codex"], ["codex"], base(reader)) == ["codex"]
    end
  end

  describe "input/3 (editable)" do
    test "Enter on a pre-filled default returns the default unchanged" do
      reader = keys_reader([enter()])
      assert Prompt.input("Repo", "owner/repo", base(reader)) == "owner/repo"
    end

    test "Backspace then typed characters edit the buffer" do
      reader = keys_reader([backspace(), chars("xyz"), enter()])
      assert Prompt.input("Label", "ab", base(reader)) == "axyz"
    end

    test "nil default starts from an empty buffer" do
      reader = keys_reader([chars("hi"), enter()])
      assert Prompt.input("Label", nil, base(reader)) == "hi"
    end

    test "a hint renders indented beneath the question, above the field" do
      parent = self()
      writer = fn data -> send(parent, {:drawn, IO.iodata_to_binary(data)}) end
      reader = keys_reader([enter()])

      assert Prompt.input("Pre-warm", "3",
               raw?: false,
               writer: writer,
               reader: reader,
               hint: "panes you expect open"
             ) == "3"

      drawn = drain_drawn()
      assert drawn =~ "Pre-warm"
      assert drawn =~ "  panes you expect open"
      # the field uses the cursor marker rather than the inline `label:`
      assert drawn =~ "❯"
      refute drawn =~ "Pre-warm: "
    end
  end

  describe "terminal lifecycle" do
    test "stty failure (non-TTY) degrades to the default without reading" do
      reader = keys_reader([])

      assert Prompt.select("Pick", ["a", "b", "c"], "b",
               raw?: true,
               writer: noop_writer(),
               reader: reader,
               stty: fn _ -> {:error, "no tty"} end
             ) == "b"
    end

    test "raw mode is entered and the terminal is always restored" do
      parent = self()
      stty = fn args -> send(parent, {:stty, args}) && :ok end
      reader = keys_reader([enter()])

      assert Prompt.select("Pick", ["a", "b"], "a",
               raw?: true,
               writer: noop_writer(),
               reader: reader,
               stty: stty
             ) == "a"

      assert_received {:stty, ["-icanon" | _]}
      assert_received {:stty, ["sane"]}
    end
  end

  defp drain_drawn(acc \\ "") do
    receive do
      {:drawn, data} -> drain_drawn(acc <> data)
    after
      0 -> acc
    end
  end
end
