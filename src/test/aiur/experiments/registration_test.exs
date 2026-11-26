defmodule Aiur.Experiments.RegistrationTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Registration, Spec}

  test "registration starts at the reached change, keeping the earliest existing registration" do
    spec = %Spec{design: %{"kind" => "before_after", "change" => %{"time" => "2026-10-09T00:00:00Z"}}}
    assert Registration.mark(spec, ~U[2026-10-08 00:00:00Z]).registered_at == nil
    assert Registration.mark(spec, ~U[2026-10-09 00:00:00Z]).registered_at == "2026-10-09T00:00:00Z"
    frozen = %{spec | registered_at: "2026-10-07T00:00:00Z"}
    assert Registration.mark(frozen, ~U[2026-10-10 00:00:00Z]).registered_at == frozen.registered_at
  end

  test "drafts wait for activation before registering a reached change" do
    spec = %Spec{status: "draft", design: %{"kind" => "before_after", "change" => %{"time" => "2026-10-09T00:00:00Z"}}}
    assert Registration.mark(spec, ~U[2026-10-10 00:00:00Z]).registered_at == nil
    assert Registration.mark(%{spec | status: "active"}, ~U[2026-10-10 00:00:00Z]).registered_at == "2026-10-09T00:00:00Z"
  end

  test "an A/B design waits for explicit registration" do
    spec = %Spec{design: %{"kind" => "ab"}}
    assert Registration.mark(spec, ~U[2026-10-09 00:00:00Z]) == spec
  end
end
