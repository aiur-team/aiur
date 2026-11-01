import Config
config :local_host, start_server: config_env() != :test
