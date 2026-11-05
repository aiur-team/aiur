defmodule AgentConversation.VoiceTest do
  use ExUnit.Case, async: true

  alias AgentConversation.Voice

  defp host(features, opts \\ []) do
    {:ok, host} = AgentConversation.HostFixture.host("conv-voice", Keyword.merge([features: features], opts))
    host
  end

  test "dictation and two-way voice require both the host mount and the transport report" do
    dictation_only = host(%{voice: :dictation})
    two_way = host(%{voice: :two_way})

    assert {:ok, %{dictation: true}} = Voice.capabilities(dictation_only, "conv-voice", {:ok, %{dictation: true}})
    assert {:error, :unavailable} = Voice.capabilities(dictation_only, "conv-voice", {:ok, %{two_way: true}})
    assert {:ok, %{two_way: true}} = Voice.capabilities(two_way, "conv-voice", {:ok, %{two_way: true, dictation: true}})
  end

  test "a host without a voice mount reports unavailable without asking the transport" do
    assert {:error, :unavailable} = Voice.capabilities(host(%{voice: :none}), "conv-voice", {:ok, %{dictation: true}})
    assert {:error, :unavailable} = Voice.capabilities(host(%{voice: false}), "conv-voice", {:ok, %{dictation: true}})
  end

  test "a permission-denied transport report stays distinct from unavailable" do
    assert {:error, :permission_denied} =
             Voice.capabilities(host(%{voice: :dictation}), "conv-voice", {:error, :permission_denied})
  end

  test "a transport that never implements the callback reports not implemented" do
    assert {:error, :not_implemented} = Voice.capabilities(host(%{voice: :dictation}), "conv-voice", :unsupported)
  end

  test "opening a voice session needs the mount, the report and the scope grant" do
    granted = host(%{voice: :dictation})

    assert {:ok, %{mode: :dictation, connection: :connected}} =
             Voice.open(granted, "conv-voice", :dictation, {:ok, %{dictation: true}})

    assert {:error, :unavailable} =
             Voice.open(host(%{voice: :none}), "conv-voice", :dictation, {:ok, %{dictation: true}})
  end

  test "permission-denied and out-of-scope denials surface before any session opens" do
    read_only = host(%{voice: :dictation}, actions: [:read])

    assert {:error, :permission_denied} = Voice.open(read_only, "conv-voice", :dictation, {:ok, %{dictation: true}})

    assert {:error, :out_of_scope} =
             Voice.open(host(%{voice: :dictation}), "conv-elsewhere", :dictation, {:ok, %{dictation: true}})
  end

  test "a dropped connection stays reconnecting and keeps the chosen mode" do
    voice = Voice.from_report({:ok, %{two_way: true}})
    {:ok, voice} = Voice.start(voice, :two_way)

    dropped = Voice.disconnect(voice)
    assert Voice.status(dropped) == :reconnecting
    assert dropped.mode == :two_way
    assert Voice.status(Voice.reconnect(dropped)) == :active
  end

  test "every status has reader-facing text" do
    for status <- [:available, :active, :unavailable, :permission_denied, :reconnecting],
        do: assert(is_binary(Voice.label(status)))
  end
end
