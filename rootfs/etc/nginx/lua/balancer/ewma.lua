-- Original Authors: Shiv Nagarajan & Scott Francis
-- Accessed: March 12, 2018
-- Inspiration drawn from:
-- https://github.com/twitter/finagle/blob/1bc837c4feafc0096e43c0e98516a8e1c50c4421
--   /finagle-core/src/main/scala/com/twitter/finagle/loadbalancer/PeakEwma.scala


local util = require("util")
local split = require("util.split")
local cjson = require("cjson.safe")

local DECAY_TIME = 10 -- this value is in seconds
local PICK_SET_SIZE = 2
local NEW_ENDPOINT_PENALTY_FACTOR = 1.0 -- 1 is no penalty

local _M = { name = "ewma" }

local function decay_ewma(ewma, last_touched_at, rtt, now)
  local td = now - last_touched_at
  td = (td > 0) and td or 0
  local weight = math.exp(-td/DECAY_TIME)

  ewma = ewma * weight + rtt * (1.0 - weight)
  return ewma
end

local function get_or_update_ewma(self, upstream, rtt, update)
  local ewma = self.ewma[upstream] or 0

  local now = ngx.now()
  local last_touched_at = self.ewma_last_touched_at[upstream] or 0
  ewma = decay_ewma(ewma, last_touched_at, rtt, now)

  if not update then
    return ewma, nil
  end

  -- ngx.log(ngx.ERR, "UPDATING " .. tostring(upstream) .. " from " .. tostring(self.ewma[upstream]) .. " to " .. tostring(ewma) .. " rtt is " .. tostring(rtt))

  self.ewma[upstream] = ewma
  self.ewma_last_touched_at[upstream] = now
  return ewma, nil
end


local function score(self, upstream)
  -- Original implementation used names
  -- Endpoints don't have names, so passing in IP:Port as key instead
  local upstream_name = upstream.address .. ":" .. upstream.port
  return get_or_update_ewma(self, upstream_name, 0, false)
end

-- implementation similar to https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle
-- or https://en.wikipedia.org/wiki/Random_permutation
-- loop from 1 .. k
-- pick a random value r from the remaining set of unpicked values (i .. n)
-- swap the value at position i with the value at position r
local function shuffle_peers(peers, k)
  for i=1, k do
    local rand_index = math.random(i,#peers)
    peers[i], peers[rand_index] = peers[rand_index], peers[i]
  end
  -- peers[1 .. k] will now contain a randomly selected k from #peers
end

local function pick_and_score(self, peers, k)
  shuffle_peers(peers, k)
  local lowest_score_index = 1
  local lowest_score = score(self, peers[lowest_score_index])
  for i = 2, k do
    local new_score = score(self, peers[i])
    if new_score < lowest_score then
      lowest_score_index, lowest_score = i, new_score
    end
  end
  return peers[lowest_score_index]
end

function _M.balance(self)
  local peers = self.peers
  local endpoint = peers[1]

  if #peers > 1 then
    local k = (#peers < PICK_SET_SIZE) and #peers or PICK_SET_SIZE
    local peer_copy = util.deepcopy(peers)
    endpoint = pick_and_score(self, peer_copy, k)
  end

  -- TODO(elvinefendi) move this processing to _M.sync
  return endpoint.address .. ":" .. endpoint.port
end

function _M.after_balance(self)
  local response_time = tonumber(split.get_first_value(ngx.var.upstream_response_time)) or 0
  local connect_time = tonumber(split.get_first_value(ngx.var.upstream_connect_time)) or 0
  local rtt = connect_time + response_time
  local upstream = split.get_first_value(ngx.var.upstream_addr)

  if util.is_blank(upstream) then
    return
  end
  get_or_update_ewma(self, upstream, rtt, true)
end

function _M.sync(self, backend)
  self.traffic_shaping_policy = backend.trafficShapingPolicy
  self.alternative_backends = backend.alternativeBackends

  -- ngx.log(ngx.ERR, "\nSUMMARRY ------ \n\n" .. cjson.encode(self.ewma) .. "\n\n---------- ENDSUMMARY")

  local changed = not util.deep_compare(self.peers, backend.endpoints)
  if not changed then
    return
  end

  -- Get the average for the ewma
  local old_ewma_average = 0
  for _, endpoint in ipairs(self.peers) do
    local name = endpoint.address .. ":" .. endpoint.port
    old_ewma_average = old_ewma_average + (self.ewma[name] or 0)
  end
  old_ewma_average = (old_ewma_average / #self.peers) or 0

  -- Preserve the values for remaining endpoints and set the new ones to
  -- the average times a constant
  local new_ewma = {}
  local new_ewma_last_touched_at = {}
  local now = ngx.now()
  for _, endpoint in ipairs(backend.endpoints) do
    local name = endpoint.address .. ":" .. endpoint.port
    if self.ewma[name] ~= nil then
      -- Old endpoint
      -- ngx.log(ngx.ERR, "Copying old endpoint " .. name .. "with wma " .. tostring(self.ewma[name]))
      new_ewma[name] = self.ewma[name]
      new_ewma_last_touched_at[name] = self.ewma_last_touched_at[name]
    else
      -- New endpoint
      -- ngx.log(ngx.ERR, "Making new endpoint " .. name .. "with wma " .. tostring(old_ewma_average * NEW_ENDPOINT_PENALTY_FACTOR))
      new_ewma[name] = old_ewma_average * NEW_ENDPOINT_PENALTY_FACTOR
      new_ewma_last_touched_at[name] = now
    end
  end

  self.peers = backend.endpoints
  self.ewma = new_ewma
  self.ewma_last_touched_at = new_ewma_last_touched_at

  -- ngx.log(ngx.ERR, cjson.encode(self.peers))
  -- ngx.log(ngx.ERR, cjson.encode(self.ewma))
  -- ngx.log(ngx.ERR, cjson.encode(self.ewma_last_touched_at))
end

function _M.new(self, backend)
  local o = {
    peers = backend.endpoints,
    ewma = {},
    ewma_last_touched_at = {},
    traffic_shaping_policy = backend.trafficShapingPolicy,
    alternative_backends = backend.alternativeBackends,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

return _M
