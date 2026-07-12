local config = {}

config.ENABLED = true
config.DEBUG = false
config.STRICT_SOURCE_BINDING = true
config.DEBUG_SOURCE_BINDING = false

-- Palworld 1.0+ can create death-drop map objects shortly after
-- DropItem_FromEnemyDeath returns. These values only apply to already-validated
-- Pal death contexts; they do not enable broad pickup scanning.
config.ASYNC_BIND_WINDOW_SECONDS = 2.0

-- __DEPRECATED_20260713__ Location fallback is disabled by default because it
-- can overlap with mining/logging/harvesting drops near a Pal death. Kept only
-- as a diagnostic note for older builds; strict source binding does not read it.
config.ASYNC_BIND_RADIUS = 400.0

-- __DEPRECATED_20260712__ Kept only for diagnosing the old time/distance
-- matching approach. Strict source binding does not read these values.
config.MATCH_RADIUS = 550.0
config.MATCH_WINDOW_SECONDS = 4.0

config.PICKUP_DELAY_MS = 50

config.MAX_RECENT_KILLS = 64
config.MAX_PICKUP_RETRIES = 2
config.RETRY_DELAY_MS = 100

return config
