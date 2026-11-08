import Config

config :local_host,
  root: Path.expand(System.get_env("VOICE_HOST_ROOT", ".")),
  port: String.to_integer(System.get_env("VOICE_HOST_PORT", "4100")),
  provider: System.get_env("VOICE_HOST_PROVIDER", "fake"),
  llm: System.get_env("VOICE_HOST_MODEL", "fake"),
  cloud_disclosure_accepted: System.get_env("VOICE_HOST_CLOUD_ACCEPTED") == "true"
