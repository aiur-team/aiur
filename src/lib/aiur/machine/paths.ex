defmodule Aiur.Machine.Paths do
  @moduledoc "Machine pairing files alongside the boot-owned machine identity."

  alias Aiur.Identity.Store, as: IdentityStore

  @spec paths() :: %{atom() => Path.t()}
  def paths do
    dir = IdentityStore.dir()

    %{
      dir: dir,
      identity: Path.join(dir, "identity.json"),
      store: Path.join(dir, "store.json"),
      machine_key: Path.join(dir, "machine_key"),
      machine_public_key: Path.join(dir, "machine_key.pub"),
      devices: Path.join(dir, "devices.json"),
      pairing: Path.join(dir, "pairing.json"),
      known_instances: Path.join(dir, "known_instances.json")
    }
  end
end
