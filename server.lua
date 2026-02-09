local ESX = exports["es_extended"]:getSharedObject()

local state = {
  zoneIndex = 1,
  zone = nil,
  rotateAt = 0,
}

local players = {}

local function now()
  return os.time()
end

local function getZone(i)
  local z = Config.Zones[i]
  if not z then return nil end
  return {
    index = i,
    label = z.label,
    coords = z.coords,
    radius = z.radius,
  }
end

local function broadcastZone()
  if not state.zone then return end
  TriggerClientEvent('Sync:KOTH:ZoneChanged', -1, state.zone, state.rotateAt)
end

local function setZone(i)
  local z = getZone(i)
  if not z then return end
  state.zoneIndex = i
  state.zone = z
  state.rotateAt = now() + (Config.RotateMinutes * 60)
  broadcastZone()
end

local function rotateZone()
  local nextIndex = state.zoneIndex + 1
  if nextIndex > #Config.Zones then nextIndex = 1 end
  setZone(nextIndex)
end

local function ensureColumn()
  local exists = MySQL.scalar.await([[
    SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'users'
      AND COLUMN_NAME = 'time_in_koth'
  ]])

  if tonumber(exists or 0) == 0 then
    MySQL.query.await([[
      ALTER TABLE users
      ADD COLUMN time_in_koth INT NOT NULL DEFAULT 0
    ]])
  end
end

local function getIdentifier(src)
  local xPlayer = ESX.GetPlayerFromId(src)
  if not xPlayer then return nil end
  return xPlayer.identifier
end

local function initPlayer(src)
  local identifier = getIdentifier(src)
  if not identifier then return end

  local total = MySQL.scalar.await('SELECT time_in_koth FROM users WHERE identifier = ?', { identifier })
  total = tonumber(total or 0)

  players[src] = {
    identifier = identifier,
    inZone = false,
    streak = 0,
    total = total,
    dirty = 0,
  }
end

local function flushPlayer(src)
  local p = players[src]
  if not p or p.dirty <= 0 or not p.identifier then return end
  local add = p.dirty
  p.dirty = 0
  MySQL.update('UPDATE users SET time_in_koth = time_in_koth + ? WHERE identifier = ?', { add, p.identifier })
end

local function flushAll()
  for src, _ in pairs(players) do
    flushPlayer(src)
  end
end

local function addCoins(src, amount)
  if amount <= 0 then return false end
  local ok = exports.ox_inventory:AddItem(src, Config.CoinItem, amount)
  return ok == true
end

lib.callback.register('koth:getState', function(source)
  local p = players[source]
  return {
    zone = state.zone,
    rotateAt = state.rotateAt,
    stats = p and { streak = p.streak, total = p.total } or { streak = 0, total = 0 },
  }
end)

CreateThread(function()
  ensureColumn()

  state.zone = getZone(1)
  state.rotateAt = now() + (Config.RotateMinutes * 60)

  for _, src in ipairs(GetPlayers()) do
    initPlayer(tonumber(src))
  end

  broadcastZone()

  local tickSeconds = tonumber(Config.TickSeconds or 2) or 2
  if tickSeconds < 1 then tickSeconds = 1 end
  local tickMs = tickSeconds * 1000

  while true do
    Wait(tickMs)

    if state.rotateAt > 0 and now() >= state.rotateAt then
      rotateZone()
    end

    local z = state.zone
    if not z then goto continue end

    local zc = vector3(z.coords.x, z.coords.y, z.coords.z)
    local r2 = (z.radius * z.radius)
    local addSec = tickSeconds
    local holdSec = tonumber(Config.HoldSeconds or 600) or 600

    local plist = GetPlayers()
    for i = 1, #plist do
      local src = tonumber(plist[i])
      local p = players[src]
      if not p then
        initPlayer(src)
        p = players[src]
      end

      if p then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
          local c = GetEntityCoords(ped)
          local dx = c.x - zc.x
          local dy = c.y - zc.y
          local dz = c.z - zc.z
          local dist2 = (dx * dx) + (dy * dy) + (dz * dz)

          if dist2 <= r2 then
            if not p.inZone then
              p.inZone = true
              p.streak = 0
              TriggerClientEvent('Sync:KOTH:Entered', src, z)
            end

            p.streak = p.streak + addSec
            p.total = p.total + addSec
            p.dirty = p.dirty + addSec

            while p.streak >= holdSec do
              p.streak = p.streak - holdSec
              if addCoins(src, Config.RewardCoins) then
                TriggerClientEvent('Sync:KOTH:Reward', src, Config.RewardCoins)
              else
                TriggerClientEvent('Sync:KOTH:RewardFail', src)
              end
            end
          else
            if p.inZone then
              p.inZone = false
              p.streak = 0
              TriggerClientEvent('Sync:KOTH:Left', src, z)
            end
          end
        end
      end
    end

    ::continue::
  end
end)

CreateThread(function()
  while true do
    Wait(60000)
    flushAll()
  end
end)

AddEventHandler('playerJoining', function()
  local src = source
  SetTimeout(1000, function()
    initPlayer(src)
    if state.zone then
      TriggerClientEvent('Sync:KOTH:ZoneChanged', src, state.zone, state.rotateAt)
    end
  end)
end)

AddEventHandler('playerDropped', function()
  local src = source
  flushPlayer(src)
  players[src] = nil
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  flushAll()
end)
