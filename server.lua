local ESX = exports["es_extended"]:getSharedObject()

local function ms() return GetGameTimer() end
local function sNow() return os.time() end
local function v3(x) return vector3(x.x, x.y, x.z) end

local function dist2(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  local dz = a.z - b.z
  return (dx * dx) + (dy * dy) + (dz * dz)
end

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local D = (SVConfig and SVConfig.Discord) or { enabled = false }

local function mentionRole()
  if not D.mention_role_id or D.mention_role_id == '' then return '' end
  return '<@&' .. D.mention_role_id .. '>'
end

local function discord(payload)
  if not D.enabled then return end
  if not D.webhook or D.webhook == '' then return end
  local body = {
    username = D.username,
    avatar_url = D.avatar_url,
    embeds = payload.embeds or nil,
    content = payload.content or nil,
  }
  PerformHttpRequest(D.webhook, function() end, 'POST', json.encode(body), { ['Content-Type'] = 'application/json' })
end

local function isAdmin(src)
  local xPlayer = ESX.GetPlayerFromId(src)
  if not xPlayer then return false end
  local g = xPlayer.getGroup and xPlayer.getGroup() or 'user'
  return Config.AdminGroups[g] == true
end

local function getIdentifier(src)
  local xPlayer = ESX.GetPlayerFromId(src)
  if not xPlayer then return nil end
  return xPlayer.identifier
end

local function getJobName(src)
  local xPlayer = ESX.GetPlayerFromId(src)
  if not xPlayer then return nil end
  local job = xPlayer.getJob and xPlayer.getJob()
  if job and job.name then return job.name end
  return nil
end

local function genToken()
  return tostring(math.random(100000, 999999)) .. '-' .. tostring(ms())
end

local function hasVip(src)
  if not Config.VIP or Config.VIP.enabled ~= true then return false end
  local ok, res = pcall(function()
    return exports['core']:hasvip(src)
  end)
  return ok and res == true
end

local state = {
  zoneIndex = 1,
  zone = nil,
  rotateAt = 0,
  paused = false,
  contested = false,
  present = 0,
  blacklisted = {},
}

local players = {}
local nearSet = {}
local insideList = {}
local insideIndex = {}
local jobCounts = {}

local adminTokenMeta = {}
local rate = {}
local summary = {
  rewards = 0,
  suspicious = 0,
  adminActions = 0,
  last = sNow(),
  topRewards = {},
}

local function rlKey(kind, src) return kind .. ':' .. tostring(src) end

local function rateOk(kind, src)
  local key = rlKey(kind, src)
  local t = rate[key]
  local nowS = sNow()
  local waitS = tonumber(D.rateLimitSeconds or 300) or 300
  if t and (nowS - t) < waitS then return false end
  rate[key] = nowS
  return true
end

local function ensureColumn()
  local exists = MySQL.scalar.await([[
    SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'users'
      AND COLUMN_NAME = 'time_in_koth'
  ]])
  if tonumber(exists or 0) == 0 then
    MySQL.query.await([[ALTER TABLE users ADD COLUMN time_in_koth INT NOT NULL DEFAULT 0]])
  end
end

local function broadcastZone(target)
  if not state.zone then return end
  TriggerClientEvent('Sync:KOTH:ZoneChanged', target or -1, state.zone, state.rotateAt, state.paused, state.contested, state.present)
end

local function sendStatus(target, top)
  TriggerClientEvent('Sync:KOTH:Status', target or -1, state.contested, state.present, top or {})
end

local function clearPresence()
  insideList = {}
  insideIndex = {}
  jobCounts = {}
  state.present = 0
  state.contested = false
end

local function getZone(i)
  local z = Config.Zones[i]
  if not z then return nil end
  if state.blacklisted[i] then return nil end
  return { index = i, label = z.label, coords = z.coords, radius = z.radius }
end

local function setZone(i)
  local z = getZone(i)
  if not z then return false end
  state.zoneIndex = i
  state.zone = z
  state.rotateAt = sNow() + (Config.RotateMinutes * 60)
  clearPresence()
  broadcastZone()
  return true
end

local function rotateZone()
  local tries = 0
  local idx = state.zoneIndex
  while tries < #Config.Zones do
    idx = idx + 1
    if idx > #Config.Zones then idx = 1 end
    if getZone(idx) then
      setZone(idx)
      return
    end
    tries = tries + 1
  end
end

local function flushPlayer(src)
  local p = players[src]
  if not p or (p.dirty or 0) <= 0 or not p.identifier then return end
  local add = p.dirty
  p.dirty = 0
  MySQL.update('UPDATE users SET time_in_koth = time_in_koth + ? WHERE identifier = ?', { add, p.identifier })
end

local function flushAll()
  for src in pairs(players) do
    flushPlayer(src)
  end
end

local function addCoins(src, amount)
  if amount <= 0 then return false end
  return exports.ox_inventory:AddItem(src, Config.CoinItem, amount) == true
end

local function initPlayer(src)
  local identifier = getIdentifier(src)
  if not identifier then return end
  local total = MySQL.scalar.await('SELECT time_in_koth FROM users WHERE identifier = ?', { identifier })
  total = tonumber(total or 0)
  local job = getJobName(src)

  players[src] = {
    identifier = identifier,
    job = job,
    vip = hasVip(src),
    inZone = false,
    streak = 0,
    total = total,
    dirty = 0,
    lastPos = nil,
    lastPosAt = 0,
    lastTickAt = ms(),
    suspicious = 0,
    blockUntil = 0,
  }
end

local function removeInside(src, p)
  local idx = insideIndex[src]
  if not idx then return end
  local last = insideList[#insideList]
  insideList[idx] = last
  insideList[#insideList] = nil
  insideIndex[src] = nil
  if last then insideIndex[last] = idx end

  if p and p.job and jobCounts[p.job] then
    jobCounts[p.job] = jobCounts[p.job] - 1
    if jobCounts[p.job] <= 0 then jobCounts[p.job] = nil end
  end
end

local function addInside(src, p)
  if insideIndex[src] then return end
  insideList[#insideList + 1] = src
  insideIndex[src] = #insideList
  if p and p.job then
    jobCounts[p.job] = (jobCounts[p.job] or 0) + 1
  end
end

local function computeContested()
  local count = #insideList
  state.present = count
  local contested = false

  if Config.Contested.enabled and count >= (Config.Contested.minPresent or 2) then
    if Config.Contested.mode == 'job' then
      local distinct = 0
      for _ in pairs(jobCounts) do
        distinct = distinct + 1
        if distinct >= 2 then contested = true break end
      end
    else
      contested = true
    end
  end

  local changed = (contested ~= state.contested)
  state.contested = contested
  return changed
end

local function calcReward(present, base)
  if not Config.RewardScaling.enabled then return base end
  local startAt = tonumber(Config.RewardScaling.startAt or 8) or 8
  local minF = tonumber(Config.RewardScaling.minFactor or 0.4) or 0.4
  if present < startAt then return base end
  local f = startAt / math.max(1, present)
  if f < minF then f = minF end
  local out = math.floor((base * f) + 0.5)
  if out < 1 then out = 1 end
  return out
end

local function summaryBumpReward(src, amount)
  summary.rewards = summary.rewards + 1
  local name = GetPlayerName(src) or ('id:' .. src)
  summary.topRewards[name] = (summary.topRewards[name] or 0) + (tonumber(amount) or 0)
end

local function summaryBumpSuspicious()
  summary.suspicious = summary.suspicious + 1
end

local function summaryBumpAdmin()
  summary.adminActions = summary.adminActions + 1
end

local function sendSummary()
  if not D.enabled then return end
  local nowS = sNow()
  local every = tonumber(D.summaryEverySeconds or 600) or 600
  if (nowS - (summary.last or 0)) < every then return end
  summary.last = nowS

  local top = {}
  for k, v in pairs(summary.topRewards) do
    top[#top + 1] = { n = k, v = v }
  end
  table.sort(top, function(a, b) return a.v > b.v end)

  local lines = {}
  local limit = math.min(5, #top)
  for i = 1, limit do
    lines[#lines + 1] = ('%d) %s: %d'):format(i, top[i].n, top[i].v)
  end
  local topText = (#lines > 0) and table.concat(lines, '\n') or '—'

  local z = state.zone and state.zone.label or '—'
  local rot = state.paused and 'PAUSED' or tostring(state.rotateAt or 0)

  discord({
    embeds = {{
      title = 'KOTH Summary',
      description = ('Zone: %s\nRotateAt: %s\nPresent: %d\nContested: %s\nRewards: %d\nSuspicious: %d\nAdminActions: %d\n\nTop rewards:\n%s')
        :format(z, rot, state.present or 0, tostring(state.contested), summary.rewards, summary.suspicious, summary.adminActions, topText)
    }}
  })

  summary.rewards = 0
  summary.suspicious = 0
  summary.adminActions = 0
  summary.topRewards = {}
end

local function bumpSuspicious(src, amount, reason)
  local p = players[src]
  if not p then return end
  p.suspicious = (p.suspicious or 0) + (amount or 1)
  summaryBumpSuspicious()

  local threshold = tonumber(D.suspiciousThreshold or 6) or 6
  if D.enabled and D.logSuspicious and p.suspicious >= threshold then
    if rateOk('suspicious', src) then
      discord({
        content = mentionRole(),
        embeds = {{
          title = 'KOTH Suspicious',
          description = ('%s (%d)\nScore: %d\nReason: %s'):format(GetPlayerName(src) or 'unknown', src, p.suspicious, reason or '—')
        }}
      })
    end
  end
end

local function getTopStreaks(count)
  local c = tonumber(count or 3) or 3
  if c < 1 then c = 1 end
  local items = {}
  for i = 1, #insideList do
    local src = insideList[i]
    local p = players[src]
    if p then
      items[#items + 1] = { id = src, n = (GetPlayerName(src) or ('id:' .. src)), s = (p.streak or 0) }
    end
  end
  table.sort(items, function(a, b) return a.s > b.s end)
  local out = {}
  local lim = math.min(c, #items)
  for i = 1, lim do
    out[#out + 1] = { id = items[i].id, name = items[i].n, streak = math.floor(items[i].s or 0) }
  end
  return out
end

local function adminTokenEnsure(src)
  if not isAdmin(src) then return nil end
  local ttl = tonumber(Config.Security.adminTokenTtlSeconds or 300) or 300
  local rotate = tonumber(Config.Security.adminTokenRotateSeconds or 120) or 120
  local meta = adminTokenMeta[src]
  local nowS = sNow()

  if not meta or not meta.token or nowS >= (meta.exp or 0) or nowS >= (meta.rot or 0) then
    local t = genToken()
    adminTokenMeta[src] = { token = t, exp = nowS + ttl, rot = nowS + rotate }
    return t
  end

  return meta.token
end

local function adminTokenValid(src, token)
  if not isAdmin(src) then return false end
  local meta = adminTokenMeta[src]
  if not meta or not meta.token then return false end
  if token ~= meta.token then return false end
  if sNow() >= (meta.exp or 0) then return false end
  return true
end

lib.callback.register('koth:getState', function(source)
  local p = players[source]
  local t = adminTokenEnsure(source)
  return {
    zone = state.zone,
    rotateAt = state.rotateAt,
    paused = state.paused,
    contested = state.contested,
    present = state.present,
    stats = p and { streak = math.floor(p.streak or 0), total = math.floor(p.total or 0) } or { streak = 0, total = 0 },
    adminToken = t,
    vip = (p and p.vip) == true,
  }
end)

lib.callback.register('koth:getAdminData', function(source, token)
  if not adminTokenValid(source, token) then return { ok = false } end

  local list = {}
  for i = 1, #insideList do
    local src = insideList[i]
    local p = players[src]
    if p then
      list[#list + 1] = {
        id = src,
        name = GetPlayerName(src) or ('id:' .. src),
        streak = math.floor(p.streak or 0),
        total = math.floor(p.total or 0),
        suspicious = p.suspicious or 0,
        blocked = (p.blockUntil or 0) > sNow(),
        vip = p.vip == true,
      }
    end
  end

  table.sort(list, function(a, b) return (a.streak or 0) > (b.streak or 0) end)

  local bl = {}
  for i = 1, #Config.Zones do
    bl[i] = state.blacklisted[i] == true
  end

  return {
    ok = true,
    zone = state.zone,
    rotateAt = state.rotateAt,
    paused = state.paused,
    contested = state.contested,
    present = state.present,
    blacklisted = bl,
    players = list,
  }
end)

lib.callback.register('koth:adminAction', function(source, token, action, data)
  if not adminTokenValid(source, token) then return { ok = false } end
  if not action then return { ok = false } end

  local actor = GetPlayerName(source) or 'unknown'

  local function logAdmin(txt)
    summaryBumpAdmin()
    if D.enabled and D.logAdmin then
      discord({ embeds = {{ title = 'KOTH Admin', description = txt }} })
    end
  end

  if action == 'pause' then
    state.paused = true
    broadcastZone()
    logAdmin(('Paused by %s'):format(actor))
    return { ok = true }
  end

  if action == 'resume' then
    state.paused = false
    state.rotateAt = sNow() + (Config.RotateMinutes * 60)
    broadcastZone()
    logAdmin(('Resumed by %s'):format(actor))
    return { ok = true }
  end

  if action == 'next' then
    state.paused = false
    flushAll()
    rotateZone()
    logAdmin(('Next zone by %s'):format(actor))
    return { ok = true }
  end

  if action == 'set' then
    local idx = tonumber(data and data.index)
    if not idx or not Config.Zones[idx] then return { ok = false } end
    if state.blacklisted[idx] then return { ok = false } end
    state.paused = false
    flushAll()
    local ok = setZone(idx)
    if ok then logAdmin(('Set zone #%d by %s'):format(idx, actor)) end
    return { ok = ok }
  end

  if action == 'toggleBlacklist' then
    local idx = tonumber(data and data.index)
    if not idx or not Config.Zones[idx] then return { ok = false } end
    state.blacklisted[idx] = not state.blacklisted[idx]
    if state.blacklisted[state.zoneIndex] then
      flushAll()
      rotateZone()
    else
      broadcastZone()
    end
    logAdmin(('Blacklist toggle #%d by %s'):format(idx, actor))
    return { ok = true }
  end

  if action == 'resetStreak' then
    local target = tonumber(data and data.id)
    local p = target and players[target] or nil
    if not p then return { ok = false } end
    p.streak = 0
    logAdmin(('Reset streak: %s (%d) by %s'):format(GetPlayerName(target) or 'unknown', target, actor))
    return { ok = true }
  end

  if action == 'block' then
    local target = tonumber(data and data.id)
    local p = target and players[target] or nil
    if not p then return { ok = false } end
    local seconds = tonumber(Config.Security.adminBlockSeconds or 120) or 120
    p.blockUntil = sNow() + seconds
    p.streak = 0
    logAdmin(('Block progress %ds: %s (%d) by %s'):format(seconds, GetPlayerName(target) or 'unknown', target, actor))
    return { ok = true }
  end

  if action == 'kickFromHill' then
    local target = tonumber(data and data.id)
    local p = target and players[target] or nil
    if not p then return { ok = false } end
    local seconds = tonumber(Config.Security.adminBlockSeconds or 120) or 120
    p.blockUntil = sNow() + seconds
    p.streak = 0

    if p.inZone then
      p.inZone = false
      removeInside(target, p)
      computeContested()
      sendStatus(-1, getTopStreaks(Config.HUD.topCount or 3))
      TriggerClientEvent('Sync:KOTH:Left', target, state.zone)
    end

    logAdmin(('KickFromHill %ds: %s (%d) by %s'):format(seconds, GetPlayerName(target) or 'unknown', target, actor))
    return { ok = true }
  end

  return { ok = false }
end)

RegisterNetEvent('esx:setJob', function(job)
  local src = source
  local p = players[src]
  if not p then return end
  local old = p.job
  local new = job and job.name or nil
  if old == new then return end
  p.job = new

  if p.inZone then
    if old and jobCounts[old] then
      jobCounts[old] = jobCounts[old] - 1
      if jobCounts[old] <= 0 then jobCounts[old] = nil end
    end
    if new then
      jobCounts[new] = (jobCounts[new] or 0) + 1
    end
    if computeContested() then
      sendStatus(-1, getTopStreaks(Config.HUD.topCount or 3))
    end
  end
end)

CreateThread(function()
  ensureColumn()
  state.blacklisted = {}
  if not setZone(1) then rotateZone() end

  for _, id in ipairs(GetPlayers()) do
    initPlayer(tonumber(id))
  end
  broadcastZone()

  local sweepEvery = tonumber(Config.Sweep.everyMs or 8000) or 8000
  local nearDist2 = (tonumber(Config.Sweep.nearDist or 900.0) or 900.0) ^ 2
  local hardFar2 = (tonumber(Config.Sweep.hardFarDist or 2500.0) or 2500.0) ^ 2

  while true do
    Wait(sweepEvery)
    local z = state.zone
    if not z then goto continue end
    local zc = v3(z.coords)
    local newNear = {}
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
          local pos = vector3(c.x, c.y, c.z)
          local d2z = dist2(pos, zc)
          if d2z <= nearDist2 or insideIndex[src] or d2z <= hardFar2 then
            newNear[src] = true
          end
        end
      end
    end

    nearSet = newNear
    ::continue::
  end
end)

CreateThread(function()
  local loopMs = tonumber(Config.Tick.loopMs or 500) or 500
  if loopMs < 250 then loopMs = 250 end

  local inZoneMinMs = tonumber(Config.Tick.inZoneMinMs or 700) or 700
  if inZoneMinMs < loopMs then inZoneMinMs = loopMs end

  local tele2 = (tonumber(Config.Security.teleportDist or 250.0) or 250.0) ^ 2
  local teleWin = tonumber(Config.Security.teleportWindowMs or 2000) or 2000

  local lastStatusAt = 0
  local statusEvery = 5000

  while true do
    Wait(loopMs)

    sendSummary()

    if not state.paused and state.rotateAt > 0 and sNow() >= state.rotateAt then
      flushAll()
      rotateZone()
    end

    local z = state.zone
    if not z then goto continue end

    local zc = v3(z.coords)
    local r2 = (z.radius * z.radius)
    local holdSecBase = tonumber(Config.HoldSeconds or 600) or 600
    local nowMs = ms()
    local nowS = sNow()

    local iter = {}
    for src in pairs(nearSet) do iter[#iter + 1] = src end
    for i = 1, #insideList do
      local src = insideList[i]
      if not nearSet[src] then iter[#iter + 1] = src end
    end

    for i = 1, #iter do
      local src = iter[i]
      local p = players[src]
      if not p then
        initPlayer(src)
        p = players[src]
      end
      if not p then goto nextPlayer end

      local ped = GetPlayerPed(src)
      if not ped or ped == 0 then goto nextPlayer end

      local c = GetEntityCoords(ped)
      local pos = vector3(c.x, c.y, c.z)

      local dt = (nowMs - (p.lastTickAt or nowMs)) / 1000.0
      dt = clamp(dt, 0.0, 3.0)
      p.lastTickAt = nowMs

      if p.lastPos and (nowMs - (p.lastPosAt or 0)) <= teleWin then
        if dist2(pos, p.lastPos) >= tele2 then
          bumpSuspicious(src, 2, 'Teleport-like movement')
          p.streak = 0
        end
      end
      p.lastPos = pos
      p.lastPosAt = nowMs

      local d2z = dist2(pos, zc)
      local inside = d2z <= r2

      if inside then
        if not p.inZone then
          p.inZone = true
          p.streak = 0
          addInside(src, p)
          if computeContested() then
            sendStatus(-1, getTopStreaks(Config.HUD.topCount or 3))
          end
          TriggerClientEvent('Sync:KOTH:Entered', src, z)
        end

        if dt > 0 then
          p.total = (p.total or 0) + dt
          p.dirty = (p.dirty or 0) + dt
        end

        local blocked = (p.blockUntil or 0) > nowS
        local progressAllowed = not blocked
        if Config.Contested.enabled and Config.Contested.contestedStopsProgress and state.contested then
          progressAllowed = false
        end

        if progressAllowed then
          local vipFactor = 1.0
          if p.vip and Config.VIP and Config.VIP.enabled == true then
            vipFactor = tonumber(Config.VIP.progressFactor or 0.8) or 0.8
            vipFactor = clamp(vipFactor, 0.1, 1.0)
          end

          local holdSec = holdSecBase * vipFactor

          p.streak = (p.streak or 0) + dt
          while p.streak >= holdSec do
            p.streak = p.streak - holdSec

            local reward = calcReward(state.present or 0, Config.RewardCoins)

            if p.vip and Config.VIP and Config.VIP.enabled == true then
              local bonus = tonumber(Config.VIP.rewardBonus or 0.2) or 0.2
              if bonus < 0 then bonus = 0 end
              reward = math.floor((reward * (1.0 + bonus)) + 0.5)
              if reward < 1 then reward = 1 end
            end

            if addCoins(src, reward) then
              TriggerClientEvent('Sync:KOTH:Reward', src, reward)
              summaryBumpReward(src, reward)
              if D.enabled and D.logRewards and D.rewardsIndividualLog and rateOk('reward', src) then
                discord({ embeds = {{ title = 'KOTH Reward', description = ('%s (%d) +%d %s'):format(GetPlayerName(src) or 'unknown', src, reward, Config.CoinItem) }} })
              end
            else
              TriggerClientEvent('Sync:KOTH:RewardFail', src)
              bumpSuspicious(src, 1, 'Reward add failed')
            end
          end
        end

        if (p.dirty or 0) >= (Config.DB.flushDirtyAtSeconds or 45) then
          flushPlayer(src)
        end
      else
        if p.inZone then
          p.inZone = false
          p.streak = 0
          removeInside(src, p)
          if computeContested() then
            sendStatus(-1, getTopStreaks(Config.HUD.topCount or 3))
          end
          TriggerClientEvent('Sync:KOTH:Left', src, z)
        end
      end

      ::nextPlayer::
    end

    if (nowMs - lastStatusAt) >= statusEvery then
      lastStatusAt = nowMs
      sendStatus(-1, getTopStreaks(Config.HUD.topCount or 3))
    end

    ::continue::
  end
end)

CreateThread(function()
  local every = tonumber(Config.DB.flushEveryMs or 60000) or 60000
  if every < 15000 then every = 15000 end
  while true do
    Wait(every)
    flushAll()
  end
end)

CreateThread(function()
  local every = 60
  if Config.VIP and Config.VIP.refreshEverySeconds then
    every = tonumber(Config.VIP.refreshEverySeconds) or 60
  end
  if every < 15 then every = 15 end

  while true do
    Wait(every * 1000)
    local plist = GetPlayers()
    for i = 1, #plist do
      local src = tonumber(plist[i])
      local p = players[src]
      if p then
        p.vip = hasVip(src)
      end
    end
  end
end)

AddEventHandler('playerJoining', function()
  local src = source
  SetTimeout(1000, function()
    initPlayer(src)
    broadcastZone(src)
    sendStatus(src, getTopStreaks(Config.HUD.topCount or 3))
    adminTokenEnsure(src)
  end)
end)

AddEventHandler('playerDropped', function()
  local src = source
  local p = players[src]
  flushPlayer(src)
  players[src] = nil
  nearSet[src] = nil
  adminTokenMeta[src] = nil

  if p and p.inZone then
    removeInside(src, p)
    if computeContested() then
      sendStatus(-1, getTopStreaks(Config.HUD.topCount or 3))
    end
  end
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  flushAll()
end)

exports('GetCurrentZone', function()
  return state.zone
end)

exports('IsContested', function()
  return state.contested == true
end)

exports('GetPresentCount', function()
  return tonumber(state.present or 0) or 0
end)

exports('GetRotateAt', function()
  return tonumber(state.rotateAt or 0) or 0
end)

exports('GetPlayerTimeInKoth', function(src)
  local p = players[tonumber(src)]
  if not p then return 0 end
  return math.floor(tonumber(p.total or 0) or 0)
end)
