defmodule Aiur.Events.InstanceIdTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.InstanceId

  defmodule FakeIdentity do
    def instance_id, do: "m26chars/abc123"
  end

  defmodule NilIdentity do
    def instance_id, do: nil
  end

  defmodule EmptyIdentity do
    def instance_id, do: ""
  end

  defmodule RaisingIdentity do
    def instance_id, do: raise("identity unavailable")
  end

  defmodule ThrowingIdentity do
    def instance_id, do: throw(:identity_unavailable)
  end

  defmodule ExitingIdentity do
    def instance_id, do: exit(:identity_unavailable)
  end

  setup do
    previous = Application.fetch_env!(:aiur, InstanceId)
    on_exit(fn -> Application.put_env(:aiur, InstanceId, previous) end)
  end

  test "defaults to the identity facade" do
    assert Application.fetch_env!(:aiur, InstanceId) == Aiur.Identity
  end

  test "returns the configured provider's instance id" do
    put_provider(FakeIdentity)

    assert InstanceId.current() == {:ok, "m26chars/abc123"}
  end

  test "nil, empty, or failing providers are identity unavailable" do
    for provider <- [NilIdentity, EmptyIdentity, RaisingIdentity, ThrowingIdentity, ExitingIdentity] do
      put_provider(provider)

      assert InstanceId.current() == {:error, :identity_unavailable}
    end
  end

  defp put_provider(provider), do: Application.put_env(:aiur, InstanceId, provider)
end
