local zone, rotateAt, paused, contested, present = nil, 0, false, false, 0
local centerBlip, radiusBlip = nil, nil

local inZone = false
local streak = 0
local total = 0
local vip = false

local adminToken = nil
local top = {}

local function sNow() return os.time() end

local function formatTimeLeft(ts)
  local left = math.max(0, (ts or 0) - sNow())
  local m = math.floor(left / 60)
  local s = left - (m * 60)
  return string.format('%02d:%02d', m, s)
end

local function clearBlips()
  if centerBlip then RemoveBlip(centerBlip) centerBlip = nil end
  if radiusBlip then RemoveBlip(radiusBlip) radiusBlip = nil end
end

local function setBlips(z)
  clearBlips()
  if not Config.Blip.enabled or not z then return end

  centerBlip = AddBlipForCoord(z.coords.x, z.coords.y, z.coords.z)
  SetBlipSprite(centerBlip, Config.Blip.sprite)
  SetBlipScale(centerBlip, Config.Blip.scale)
  SetBlipColour(centerBlip, Config.Blip.colour)
  SetBlipAsShortRange(centerBlip, false)

  BeginTextCommandSetBlipName('STRING')
  AddTextComponentString(('%s: %s'):format(Config.Blip.name, z.label))
  EndTextCommandSetBlipName(centerBlip)

  radiusBlip = AddBlipForRadius(z.coords.x, z.coords.y, z.coords.z, z.radius + 0.0)
  SetBlipColour(radiusBlip, Config.Blip.colour)
  SetBlipAlpha(radiusBlip, Config.Blip.radiusAlpha or 90)
end

local function hudText()
  if not Config.HUD.enabled or not zone then return nil end

  local rot = paused and 'PAUSED' or formatTimeLeft(rotateAt)
  local st = contested and ('CONTESTED (%d)'):format(present or 0) or ('CLEAR (%d)'):format(present or 0)

  local need = Config.HoldSeconds or 600
  if vip and Config.VIP and Config.VIP.enabled == true then
    local f = tonumber(Config.VIP.progressFactor or 0.8) or 0.8
    if f < 0.1 then f = 0.1 end
    if f > 1.0 then f = 1.0 end
    need = math.floor((need * f) + 0.5)
    if need < 1 then need = 1 end
  end

  local s = math.floor(streak or 0)
  local rem = math.max(0, need - s)
  local pct = math.floor((math.min(need, s) / need) * 100)

  local lines = {}
  lines[#lines + 1] = ('KOTH | %s'):format(zone.label)
  lines[#lines + 1] = ('Změna: %s | %s'):format(rot, st)

  if inZone then
    lines[#lines + 1] = ('Reward: %d%% | zbývá %ds'):format(pct, rem)
  else
    lines[#lines + 1] = 'Mimo zónu'
  end

  if vip then
    lines[#lines + 1] = 'VIP: aktivní'
  end

  if Config.HUD.showTop and top and #top > 0 then
    local c = math.min(#top, Config.HUD.topCount or 3)
    lines[#lines +[#lines + 1] = 'Top streak:'
    for i = 1, c do
      lines[#lines + 1] = ('%d) %s - %ds'):format(i, top[i].name or '—', top[i].streak or 0)
    end
  end

  return table.concat(lines, '\n')
end

local function hudTick()
  local text = hudText()
  if text then
    lib.showTextUI(text, { position = 'left-center' })
  else
    lib.hideTextUI()
  end
end

local function fetchState()
  local data = lib.callback.await('koth:getState', false)
  if not data then return end
  zone = data.zone
  rotateAt = data.rotateAt or 0
  paused = data.paused == true
  contested = data.contested == true
  present = data.present or 0
  adminToken = data.adminToken or adminToken
  vip = data.vip == true

  streak = (data.stats and data.stats.streak) or streak
  total = (data.stats and data.stats.total) or total

  setBlips(zone)
end

RegisterNetEvent('Sync:KOTH:ZoneChanged', function(z, rAt, p, c, pr)
  zone = z
  rotateAt = rAt or 0
  paused = p == true
  contested = c == true
  present = pr or 0
  setBlips(zone)

  lib.notify({
    title = 'KOTH',
    description = ('Aktivní zóna: %s'):format(zone.label),
    type = 'inform',
    position = 'top',
  })
end)

RegisterNetEvent('Sync:KOTH:Status', function(c, pr, t)
  contested = c == true
  present = pr or 0
  top = t or {}
end)

RegisterNetEvent('Sync:KOTH:Entered', function(z)
  inZone = true
  lib.notify({
    title = 'KOTH',
    description = ('V zóně: %s'):format(z.label),
    type = 'success',
    position = 'top',
  })
end)

RegisterNetEvent('Sync:KOTH:Left', function(z)
  inZone = false
  streak = 0
  lib.notify({
    title = 'KOTH',
    description = ('Mimo zónu: %s'):format(z.label),
    type = 'error',
    position = 'top',
  })
end)

RegisterNetEvent('Sync:KOTH:Reward', function(amount)
  lib.notify({
    title = 'KOTH',
    description = ('Odměna: +%d %s'):format(amount, Config.CoinItem),
    type = 'success',
    position = 'top',
  })
end)

RegisterNetEvent('Sync:KOTH:RewardFail', function()
  lib.notify({
    title = 'KOTH',
    description = 'Nepovedlo se přidat coiny.',
    type = 'error',
    position = 'top',
  })
end)

local function adminAction(action, data)
  if not adminToken then
    fetchState()
    if not adminToken then return end
  end
  lib.callback.await('koth:adminAction', false, adminToken, action, data or {})
end

local function openAdminPlayers()
  if not adminToken then fetchState() end
  local data = lib.callback.await('koth:getAdminData', false, adminToken)
  if not data or data.ok ~= true then
    lib.notify({ title = 'KOTH', description = 'Nemáš práva.', type = 'error', position = 'top' })
    return
  end

  local opts = {}
  local list = data.players or {}
  for i = 1, #list do
    local p = list[i]
    local tag = p.blocked and 'BLOCK' or 'OK'
    local v = p.vip and 'VIP' or '—'
    opts[#opts + 1] = {
      title = ('%s [%d]'):format(p.name, p.id),
      description = ('Streak: %ds | Total: %ds | Sus: %d | %s | %s'):format(p.streak or 0, p.total or 0, p.suspicious or 0, tag, v),
      onSelect = function()
        lib.registerContext({
          id = 'koth_admin_player_' .. p.id,
          title = ('Player: %s [%d]'):format(p.name, p.id),
          options = {
            { title = 'Reset streak', onSelect = function() adminAction('resetStreak', { id = p.id }) end },
            { title = ('Block progress (%ds)'):format(Config.Security.adminBlockSeconds or 120), onSelect = function() adminAction('block', { id = p.id }) end },
            { title = ('Kick from hill (%ds)'):format(Config.Security.adminBlockSeconds or 120), onSelect = function() adminAction('kickFromHill', { id = p.id }) end },
          }
        })
        lib.showContext('koth_admin_player_' .. p.id)
      end
    }
  end

  if #opts == 0 then
    opts[#opts + 1] = { title = 'Nikdo není v zóně', disabled = true }
  end

  lib.registerContext({
    id = 'koth_admin_players',
    title = ('KOTH Players | %s'):format(data.zone and data.zone.label or '—'),
    options = opts
  })
  lib.showContext('koth_admin_players')
end

local function openAdminMenu()
  fetchState()
  if not adminToken then
    lib.notify({ title = 'KOTH', description = 'Nemáš práva.', type = 'error', position = 'top' })
    return
  end

  local data = lib.callback.await('koth:getAdminData', false, adminToken)
  if not data or data.ok ~= true then
    lib.notify({ title = 'KOTH', description = 'Nemáš práva.', type = 'error', position = 'top' })
    return
  end

  local options = {
    { title = paused and 'Resume KOTH' or 'Pause KOTH', onSelect = function() adminAction(paused and 'resume' or 'pause', {}) end },
    { title = 'Next Zone', onSelect = function() adminAction('next', {}) end },
    { title = 'Players in Zone (live)', onSelect = function() openAdminPlayers() end },
  }

  local bl = data.blacklisted or {}
  for i = 1, #Config.Zones do
    local z = Config.Zones[i]
    local isBl = bl[i] == true
    options[#options + 1] = {
      title = ('%s #%d: %s'):format(isBl and '[BL]' or '[OK]', i, z.label),
      onSelect = function()
        lib.registerContext({
          id = 'koth_admin_zone_' .. i,
          title = ('Zone #%d: %s'):format(i, z.label),
          options = {
            { title = 'Set this zone', onSelect = function() adminAction('set', { index = i }) end },
            { title = isBl and 'Unblacklist' or 'Blacklist', onSelect = function() adminAction('toggleBlacklist', { index = i }) end },
          }
        })
        lib.showContext('koth_admin_zone_' .. i)
      end
    }
  end

  lib.registerContext({ id = 'koth_admin', title = 'KOTH Admin', options = options })
  lib.showContext('koth_admin')
end

RegisterCommand('kothadmin', function()
  openAdminMenu()
end, false)

RegisterCommand('koth', function()
  fetchState()
  if not zone then return end
  lib.notify({
    title = 'KOTH',
    description = ('Zóna: %s | Změna: %s | %s'):format(zone.label, paused and 'PAUSED' or formatTimeLeft(rotateAt), contested and 'CONTESTED' or 'CLEAR'),
    type = 'inform',
    position = 'top',
  })
end, false)

CreateThread(function()
  fetchState()
  while true do
    Wait(Config.HUD.refreshMs or 350)
    hudTick()
  end
end)

CreateThread(function()
  while true do
    Wait(5)
    if Config.Marker.enabled and zone then
      local ped = PlayerPedId()
      local c = GetEntityCoords(ped)
      local dx = c.x - zone.coords.x
      local dy = c.y - zone.coords.y
      local dz = c.z - zone.coords.z
      local dist = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
      if dist <= (Config.Marker.drawDistance or 80.0) then
        DrawMarker(
          Config.Marker.type,
          zone.coords.x, zone.coords.y, zone.coords.z - 1.0,
          0.0, 0.0, 0.0,
          0.0, 0.0, 0.0,
          Config.Marker.scale.x, Config.Marker.scale.y, Config.Marker.scale.z,
          255, 255, 255, 120,
          Config.Marker.bobUpAndDown,
          Config.Marker.faceCamera,
          2,
          Config.Marker.rotate,
          nil, nil, false
        )
      end
    end
  end
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  clearBlips()
  lib.hideTextUI()
end)
