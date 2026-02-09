Config = {}

Config.RotateMinutes = 30
Config.HoldSeconds = 600
Config.RewardCoins = 300
Config.CoinItem = 'vip'

Config.VIP = {
  enabled = true,
  progressFactor = 0.80,
  rewardBonus = 0.20,
  refreshEverySeconds = 60,
}

Config.Blip = {
  enabled = true,
  sprite = 303,
  scale = 0.9,
  colour = 1,
  name = 'KOTH',
  radiusAlpha = 90,
}

Config.Marker = {
  enabled = true,
  type = 1,
  scale = vec3(2.0, 2.0, 1.0),
  drawDistance = 80.0,
  bobUpAndDown = false,
  faceCamera = true,
  rotate = false,
}

Config.Tick = {
  loopMs = 500,
  inZoneMinMs = 700,
}

Config.Sweep = {
  everyMs = 8000,
  nearDist = 900.0,
  hardFarDist = 2500.0,
}

Config.DB = {
  flushEveryMs = 60000,
  flushDirtyAtSeconds = 45,
}

Config.Contested = {
  enabled = true,
  minPresent = 2,
  mode = 'players',
  contestedStopsProgress = true,
}

Config.RewardScaling = {
  enabled = true,
  startAt = 8,
  minFactor = 0.40,
}

Config.AdminGroups = {
  admin = true,
  god = true,
  superadmin = true,
}

Config.Security = {
  teleportDist = 250.0,
  teleportWindowMs = 2000,
  adminBlockSeconds = 120,
  adminTokenTtlSeconds = 300,
  adminTokenRotateSeconds = 120,
}

Config.HUD = {
  enabled = true,
  refreshMs = 350,
  showTop = true,
  topCount = 3,
}

Config.Zones = {
  { label = 'Vespucci Beach', coords = vec3(-1203.2, -1566.7, 4.6), radius = 55.0 },
  { label = 'Mirror Park',     coords = vec3(1032.6, -770.2, 58.0), radius = 50.0 },
  { label = 'Sandy Airfield',  coords = vec3(1730.0, 3290.5, 41.1), radius = 70.0 },
  { label = 'Docks',           coords = vec3(822.2, -2988.3, 5.9),  radius = 65.0 },
  { label = 'Vinewood Sign',   coords = vec3(721.5, 1206.6, 324.9), radius = 60.0 },
}
