defmodule Aiur.Machine.Paths do
  @moduledoc "Machine pairing files alongside the boot-owned machine identity."

  @spec paths() :: %{dir: Path.t(), identity: Path.t(), store: Path.t(), machine_key: Path.t(), machine_public_key: Path.t()}
  def paths do
    dir = Aiur.Identity.Store.dir()

    %{
      dir: dir,
      identity: Path.join(dir, "identity.json"),
      store: Path.join(dir, "store.json"),
      machine_key: Path.join(dir, "machine_key"),
      machine_public_key: Path.join(dir, "machine_key.pub")
    }
  end
end
