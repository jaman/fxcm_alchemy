import Config

# Compile-time application configuration for FIXAlchemy

# Default FIX spec file (can be overridden in runtime.exs or per-connection)
# Uncomment and set path to your FIX spec file:
# config :fix_alchemy, spec_file: "FIX44.xml"

# Import environment-specific config
import_config "#{config_env()}.exs"
