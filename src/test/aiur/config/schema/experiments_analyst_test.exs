defmodule Aiur.Config.Schema.ExperimentsAnalystTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema.Experiments

  test "analyst automation defaults on, accepts explicit false and rejects null" do
    assert %Experiments{}.analyst.auto_request == true
    assert {:ok, config} = %Experiments{} |> Experiments.changeset(%{"analyst" => %{"auto_request" => false}}) |> Ecto.Changeset.apply_action(:validate)
    assert config.analyst.auto_request == false
    refute Experiments.changeset(%Experiments{}, %{"analyst" => %{"auto_request" => nil}}).valid?
  end
end
