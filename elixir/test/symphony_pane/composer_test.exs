defmodule SymphonyPane.ComposerTest do
  use ExUnit.Case, async: true

  alias SymphonyPane.Composer

  test "new/0 returns an empty state" do
    assert %{buffer: "", cursor: 0, history: []} = Composer.new()
  end

  describe "append/2" do
    test "appends a single printable byte at the cursor" do
      state = Composer.new() |> Composer.append("h") |> Composer.append("i")
      assert state.buffer == "hi"
      assert state.cursor == 2
    end

    test "drops bytes that would exceed the 64 KiB cap" do
      oversized = String.duplicate("x", 65_536)
      state = Composer.append(Composer.new(), oversized)
      assert state.buffer == oversized

      attempted = Composer.append(state, "y")
      assert attempted == state
    end

    test "rejects control characters except newline and tab" do
      state = Composer.append(Composer.new(), <<0x07>>)
      assert state.buffer == ""

      state = Composer.append(Composer.new(), "\t")
      assert state.buffer == "\t"
    end

    test "inserts at the cursor when it is mid-buffer" do
      state =
        Composer.new()
        |> Composer.append("ac")
        |> Composer.move_left()
        |> Composer.append("b")

      assert state.buffer == "abc"
      assert state.cursor == 2
    end
  end

  describe "backspace/1" do
    test "removes the character before the cursor" do
      state = Composer.append(Composer.new(), "abc") |> Composer.backspace()
      assert state.buffer == "ab"
      assert state.cursor == 2
    end

    test "is a no-op at the beginning of the buffer" do
      assert Composer.backspace(Composer.new()) == Composer.new()
    end
  end

  describe "move_left/1 and move_right/1" do
    test "move within the buffer" do
      state = Composer.append(Composer.new(), "hi")
      assert Composer.move_left(state).cursor == 1
      assert Composer.move_right(state).cursor == 2
    end

    test "do not move past the ends" do
      state = Composer.append(Composer.new(), "hi")
      assert Composer.move_left(state) |> Composer.move_left() |> Composer.move_left() |> Map.get(:cursor) == 0
      assert Composer.move_right(state).cursor == 2
    end
  end

  describe "submit/1" do
    test "returns the sanitized text and resets the buffer" do
      state = Composer.append(Composer.new(), "hello")
      {new_state, text} = Composer.submit(state)

      assert text == "hello"
      assert new_state.buffer == ""
      assert new_state.cursor == 0
      assert new_state.history == ["hello"]
    end

    test "strips control characters on submit" do
      state = %{Composer.new() | buffer: "a\x01b"}
      {_state, text} = Composer.submit(state)
      assert text == "ab"
    end
  end
end
