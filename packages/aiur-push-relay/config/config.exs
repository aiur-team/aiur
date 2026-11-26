import Config
config :aiur_push_relay, start_server: config_env() != :test
config :aiur_push_relay, allow_test_fcm: config_env() == :test
