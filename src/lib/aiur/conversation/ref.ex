defmodule Aiur.Conversation.Ref do
  @moduledoc "Versioned identity of a worker or Executor conversation."

  alias Aiur.TrackerIdentity

  defstruct v: 1, subject: nil

  @type t :: %__MODULE__{v: 1, subject: {:worker, TrackerIdentity.t()} | :executor}

  @spec worker(term()) :: {:ok, t()} | {:error, :unjoinable}
  def worker(identity) do
    if TrackerIdentity.joinable?(identity),
      do: {:ok, %__MODULE__{subject: {:worker, identity}}},
      else: {:error, :unjoinable}
  end

  @spec executor() :: t()
  def executor, do: %__MODULE__{subject: :executor}

  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{v: 1, subject: :executor}), do: "executor"

  def canonical(%__MODULE__{v: 1, subject: {:worker, identity}}) do
    {:github, owner, repository, provider_id} = TrackerIdentity.github_key(identity)
    "worker:github:#{owner}/#{repository}:#{provider_id}"
  end

  @spec conversation_id(t()) :: String.t()
  def conversation_id(ref) do
    digest =
      :sha256 |> :crypto.hash(canonical(ref)) |> Base.encode32(case: :lower, padding: false)

    "conv_" <> String.slice(digest, 0, 26)
  end
end
