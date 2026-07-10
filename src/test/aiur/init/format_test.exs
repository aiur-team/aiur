defmodule Aiur.Init.FormatTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Format

  test "dim wraps text in faint ANSI" do
    assert Format.dim("hint") == IO.ANSI.format([:faint, "hint"])
  end

  test "dim_help dims only the inline help suffix" do
    assert Format.dim_help("codex (default model)") == [
             "codex",
             IO.ANSI.format([:faint, " (default model)"])
           ]

    assert Format.dim_help("codex") == "codex"
  end

  test "value_of recovers the bare option value" do
    assert Format.value_of("codex (default model)") == "codex"
    assert Format.value_of("  claude  ") == "claude"
  end

  test "print_hint prints a dimmed two-space-indented line" do
    parent = self()

    io = %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end
    }

    assert :ok = Format.print_hint(io, "Optional")
    assert_received {:puts, rendered}
    assert rendered == Format.dim("  Optional") |> IO.chardata_to_string()
  end
end
