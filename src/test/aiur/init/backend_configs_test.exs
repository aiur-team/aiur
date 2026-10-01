defmodule Aiur.Init.BackendConfigsTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.{BackendConfigs, Templates}

  defmodule ThirdProvider do
    @spec prompt(Aiur.Init.io()) :: map()
    def prompt(io), do: %{region: io.input.("Third-provider region", "west", nil)}

    @spec config(map()) :: map()
    def config(%{region: region}), do: %{"region" => region, "features" => %{"tools" => true}}
  end

  test "selected descriptor callback alone owns questions and nested config" do
    parent = self()

    io = %{
      input: fn label, default, _hint ->
        send(parent, {:asked, label, default})
        "east"
      end
    }

    descriptors = %{"third" => %{init: ThirdProvider}, "plain" => %{}}

    answers = BackendConfigs.prompt(io, ["plain", "third"], descriptors)
    assert answers == %{"third" => %{region: "east"}}
    assert_received {:asked, "Third-provider region", "west"}, 1000

    config = BackendConfigs.config(["plain", "third"], answers, descriptors)
    assert config == %{"third" => %{"region" => "east", "features" => %{"tools" => true}}}

    rendered = Templates.render_backend_configs(config)

    assert {:ok, %{"agent" => %{"backend_configs" => ^config}}} =
             YamlElixir.read_from_string("agent:\n" <> rendered)
  end

  test "provider without callback adds neither question nor config" do
    assert BackendConfigs.prompt(%{}, ["plain"], %{"plain" => %{}}) == %{}
    assert BackendConfigs.config(["plain"], %{}, %{"plain" => %{}}) == %{}
    assert Templates.render_backend_configs(%{}) == ""
  end
end
