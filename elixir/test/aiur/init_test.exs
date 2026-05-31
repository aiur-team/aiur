defmodule Aiur.InitTest do
  use ExUnit.Case, async: true

  alias Aiur.Init

  defp io(parent) do
    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      gets: fn _prompt -> :eof end
    }
  end

  test "aborts when a config already exists and --force is not passed" do
    deps = %{existing_config_path: fn -> "/repo/.aiurconfig" end}

    assert {:error, message} = Init.run(%{force: false}, io(self()), deps)
    assert message =~ ".aiurconfig already exists"
    assert message =~ "--force"
    refute_received {:puts, _}
  end

  test "proceeds when a config exists but --force is passed" do
    deps = %{existing_config_path: fn -> "/repo/.aiurconfig" end}

    assert :ok = Init.run(%{force: true}, io(self()), deps)
    assert_received {:puts, _}
  end

  test "proceeds when no config exists" do
    deps = %{existing_config_path: fn -> nil end}

    assert :ok = Init.run(%{force: false}, io(self()), deps)
    assert_received {:puts, _}
  end
end
