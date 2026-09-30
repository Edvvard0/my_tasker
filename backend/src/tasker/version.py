"""Single source of truth for version constants exposed via ``GET /version``."""

APP_VERSION = "0.1.0"
# Bumped on any breaking change of the client-visible API/sync contract.
API_SCHEMA_VERSION = 1
# Oldest client schema the server still serves; older clients must update.
MIN_CLIENT_SCHEMA_VERSION = 1
