defmodule Aiur.CodingAgent.RegistryContractTest do
  # Characterization guard: these pass on main by design. They iterate the live
  # registry so a newly registered backend is covered the day it lands.
  use ExUnit.Case, async: true

  @moduletag :r7_characterization

  alias Aiur.CodingAgent.Registry

  @required_keys [
    :adapter,
    :transcript,
    :family,
    :can_interrupt,
    :safe_checkpoints,
    :remote_control,
    :resumable,
    :models,
    :efforts
  ]

  @required_callbacks [
    start_session: 2,
    run_turn: 4,
    stop_session: 1,
    normalize_event: 1,
    send_operator_message: 2
  ]

  @reference_keys [:remote_transport, :fallback_backend, :rate_limit_fallback, :model_catalog_backend]
  @known_checkpoints [:notification, :tool_result]

  defp failures(check) do
    for {key, entry} <- Registry.entries(), reason <- List.wrap(check.(key, entry)), do: {key, reason}
  end

  test "registry is not empty" do
    assert map_size(Registry.entries()) > 0
  end

  test "every entry declares the required capability keys" do
    assert failures(fn _key, entry ->
             for k <- @required_keys, not Map.has_key?(entry, k), do: {:missing_key, k}
           end) == []
  end

  test "every adapter implements the required backend callbacks" do
    assert failures(fn _key, entry ->
             loaded = for m <- [entry[:adapter], entry[:transcript]], not Code.ensure_loaded?(m), do: {:not_loaded, m}

             missing =
               for {fun, arity} <- @required_callbacks,
                   not function_exported?(entry[:adapter], fun, arity),
                   do: {:missing_callback, fun, arity}

             loaded ++ missing
           end) == []
  end

  test "an adapter exporting interrupt/1 declares can_interrupt" do
    assert failures(fn _key, entry ->
             Code.ensure_loaded?(entry[:adapter])

             if function_exported?(entry[:adapter], :interrupt, 1) and entry[:can_interrupt] != true,
               do: :interrupt_without_can_interrupt
           end) == []
  end

  test "immediate delivery implies no safe checkpoints" do
    assert failures(fn _key, entry ->
             if entry[:immediate_delivery] == true and entry[:safe_checkpoints] != [],
               do: {:immediate_with_checkpoints, entry[:safe_checkpoints]}
           end) == []
  end

  test "safe checkpoints are known atoms" do
    assert failures(fn _key, entry ->
             cps = entry[:safe_checkpoints]

             if not is_list(cps) or Enum.any?(cps, &(&1 not in @known_checkpoints)),
               do: {:bad_checkpoints, cps}
           end) == []
  end

  test "cross-entry references name registered backends" do
    registered = Map.keys(Registry.entries())

    assert failures(fn key, entry ->
             unknown =
               for k <- @reference_keys,
                   Map.has_key?(entry, k),
                   entry[k] not in registered,
                   do: {:unregistered_reference, k, entry[k]}

             self_fallback = if entry[:fallback_backend] == key, do: :self_fallback

             unknown ++ List.wrap(self_fallback)
           end) == []
  end
end
