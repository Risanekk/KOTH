Config = {}

Config.RotateMinutes = 30
Config.TickSeconds = 2

Config.HoldSeconds = 10 * 60
Config.RewardCoins = 300

Config.CoinItem = 'koth_coin'

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
  bobUpAndDown = false,
  faceCamera = true,
  rotate = false,
  drawDistance = 80.0,
}

Config.Zones = {
  { label = 'Vespucci Beach', coords = vec3(-1203.2, -1566.7, 4.6), radius = 55.0 },
  { label = 'Mirror Park',     coords = vec3(1032.6, -770.2, 58.0), radius = 50.0 },
  { label = 'Sandy Airfield',  coords = vec3(1730.0, 3290.5, 41.1), radius = 70.0 },
  { label = 'Docks',           coords = vec3(822.2, -2988.3, 5.9),  radius = 65.0 },
  { label = 'Vinewood Sign',   coords = vec3(721.5, 1206.6, 324.9), radius = 60.0 },
}
