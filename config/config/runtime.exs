import Config

# Runtime configuration for FIXAlchemy
# This file is executed at runtime and can use System.get_env/1

if config_env() in [:dev, :test, :prod] do
  # Configure FIX spec file path
  # Priority: Environment variable > Config value
  spec_file = System.get_env("FIX_SPEC_FILE")

  if spec_file do
    config :fix_alchemy, spec_file: spec_file
  end
end
