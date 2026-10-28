defmodule Aiur.Instance.Identity do
  @moduledoc "Stable identity for one Aiur daemon installation."

  alias Aiur.Config.Paths

  @spec current() :: String.t()
  def current, do: Application.get_env(:aiur, :booted_instance_id) || resolve()

  @doc false
  @spec configure() :: String.t()
  def configure do
    id = resolve()
    Application.put_env(:aiur, :booted_instance_id, id)
    id
  end

  defp resolve do
    configured =
      case Aiur.Config.settings() do
        {:ok, %{instance: %{id: id}}} -> id
        _ -> nil
      end

    configured || derived()
  end

  defp derived do
    {:ok, hostname} = :inet.gethostname()
    {:ok, state_dir} = Paths.runtime_state_dir()
    derive(to_string(hostname), state_dir)
  rescue
    _ -> "#{System.get_env("HOSTNAME", "aiur")}:default"
  end

  @doc false
  @spec derive(String.t(), String.t()) :: String.t()
  def derive(hostname, state_dir) do
    fingerprint =
      :crypto.hash(:sha256, Path.expand(state_dir))
      |> binary_part(0, 8)
      |> Base.url_encode64(padding: false)

    "#{hostname}:#{fingerprint}"
  end
end
