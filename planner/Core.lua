-- Every Quest: the route search. No game API in this file, so it runs in tests under plain Lua 5.1.
--
-- A route is an order of stops (a quest's accept, its objective sites, its turn-in) that keeps the
-- quest chains and the quest log's limit, and spends as little time moving as it can.
--
--   PolestarEveryQuest.NewTravel(places, net) -> t(a, b): seconds from place a to place b
--   PolestarEveryQuest.Construct(inst, t, tick) -> order: each step goes to the nearest stop it may do next
--   PolestarEveryQuest.Improve(inst, t, order, tick): moves stretches of the order while that saves time
--   PolestarEveryQuest.Cost(inst, t, order) -> seconds
--
-- inst = { n, inP, outP, dlog, preds, succs, start, cap, log0 }
--   inP[s], outP[s]: the place a stop begins and ends at (they differ on a quest walked in one go)
--   dlog[s]: +1 an accept, -1 a turn-in, 0 else; cap: the most quests in the log; log0: in it at the start
--   preds[s], succs[s]: the stops that must come before and after s
-- tick(): called often; yields between frames in game, and returns true when the budget is spent.

PolestarEveryQuest = PolestarEveryQuest or {}
local EQ = PolestarEveryQuest

local sqrt, huge = math.sqrt, math.huge

-- The route model (Forge's model.md): 60% mount at 7 yd/s, straight lines with the continent's detour,
-- flights at 30 yd/s plus 20 s for each boarding, and rides at their time plus their wait.
EQ.SPEED = 7 * 1.6
EQ.FLIGHT_SPEED = 30
EQ.FLIGHT_OVERHEAD = 20
local DETOUR = { [0] = 1.35, [1] = 1.3 }
local DETOUR_OTHER = 1.325
-- Below this many seconds of riding, walking always beats the network.
local SHORT = 400 * 1.35 / EQ.SPEED
local NEAR_NODES = 3

-- places = { X = {}, Y = {}, C = {}, n }; net = { nodes = { { c, x, y } }, taxi = { { a, b, yards } },
-- rides = { { a, b, seconds } } }, node indices from 1.
function EQ.NewTravel(places, net)
	local X, Y, C = places.X, places.Y, places.C
	local nodes = net.nodes
	local N = #nodes
	local speed = EQ.SPEED

	-- All pairs over the network.
	local D = {}
	for i = 1, N do
		local row = {}
		for j = 1, N do
			row[j] = (i == j) and 0 or huge
		end
		D[i] = row
	end
	for i = 1, N do
		for j = 1, N do
			if i ~= j and nodes[i][1] == nodes[j][1] and nodes[i][4] == nodes[j][4] then
				local dx, dy = nodes[i][2] - nodes[j][2], nodes[i][3] - nodes[j][3]
				D[i][j] = sqrt(dx * dx + dy * dy) * (DETOUR[nodes[i][1]] or DETOUR_OTHER) / speed
			end
		end
	end
	for _, r in ipairs(net.rides or {}) do
		if r[3] < D[r[1]][r[2]] then D[r[1]][r[2]] = r[3] end
	end
	for _, f in ipairs(net.taxi or {}) do
		local c = f[3] / EQ.FLIGHT_SPEED + EQ.FLIGHT_OVERHEAD
		if c < D[f[1]][f[2]] then D[f[1]][f[2]] = c end
	end
	for k = 1, N do
		local dk = D[k]
		for i = 1, N do
			local di = D[i]
			local ik = di[k]
			if ik < huge then
				for j = 1, N do
					local c = ik + dk[j]
					if c < di[j] then di[j] = c end
				end
			end
		end
	end

	-- Each place: its nearest nodes (flat: node, seconds, ...), and the time from it to every node.
	local nearN, via = {}, {}
	local function prepare(p)
		local c = C[p]
		local det = DETOUR[c] or DETOUR_OTHER
		local best = {}
		for i = 1, N do
			local nd = nodes[i]
			if nd[1] == c then
				local dx, dy = X[p] - nd[2], Y[p] - nd[3]
				local w = sqrt(dx * dx + dy * dy) * det / speed
				local at = #best + 1
				while at > 1 and best[at - 1][2] > w do at = at - 1 end
				if at <= NEAR_NODES then
					table.insert(best, at, { i, w })
					best[NEAR_NODES + 1] = nil
				end
			end
		end
		local flat, out = {}, {}
		for _, b in ipairs(best) do
			flat[#flat + 1] = b[1]
			flat[#flat + 1] = b[2]
		end
		for n = 1, N do
			local v = huge
			for i = 1, #flat, 2 do
				local cost = flat[i + 1] + D[flat[i]][n]
				if cost < v then v = cost end
			end
			out[n] = v
		end
		nearN[p], via[p] = flat, out
	end
	for p = 1, places.n do prepare(p) end

	return function(a, b)
		if a == b then return 0 end
		local d = huge
		if C[a] == C[b] then
			local dx, dy = X[a] - X[b], Y[a] - Y[b]
			d = sqrt(dx * dx + dy * dy) * (DETOUR[C[a]] or DETOUR_OTHER) / speed
			if d < SHORT then return d end
		end
		local out, near = via[a], nearN[b]
		for i = 1, #near, 2 do
			local c = out[near[i]] + near[i + 1]
			if c < d then d = c end
		end
		if d == huge then return 900 end
		return d
	end
end

function EQ.Cost(inst, t, order)
	local c, cur = 0, inst.start
	for i = 1, inst.n do
		local s = order[i]
		c = c + t(cur, inst.inP[s])
		cur = inst.outP[s]
	end
	return c
end

-- Each step: the nearest stop whose earlier stops are done, the log permitting.
function EQ.Construct(inst, t, tick)
	local n, inP, outP, dlog, preds, succs = inst.n, inst.inP, inst.outP, inst.dlog, inst.preds, inst.succs
	local cap, log = inst.cap, inst.log0
	local left, ready, nready = {}, {}, 0
	for s = 1, n do
		left[s] = #preds[s]
		if left[s] == 0 then
			nready = nready + 1
			ready[nready] = s
		end
	end
	local order, cur = {}, inst.start
	for k = 1, n do
		local best, bi, bd = nil, nil, huge
		for i = 1, nready do
			local s = ready[i]
			if not (dlog[s] > 0 and log >= cap) then
				-- At one place: hand in first, it opens the log and the follow-ups.
				local d = t(cur, inP[s]) - (dlog[s] < 0 and 0.02 or 0)
				if d < bd then best, bi, bd = s, i, d end
			end
		end
		if not best then
			best, bi = ready[1], 1
		end
		ready[bi] = ready[nready]
		ready[nready] = nil
		nready = nready - 1
		order[k] = best
		log = log + dlog[best]
		cur = outP[best]
		local after = succs[best]
		for i = 1, #after do
			local x = after[i]
			left[x] = left[x] - 1
			if left[x] == 0 then
				nready = nready + 1
				ready[nready] = x
			end
		end
		if tick then tick() end
	end
	return order
end

-- The nearest places of each place, by straight distance on its continent: the moves look only there.
local function nearLists(places, K, tick)
	local X, Y, C = places.X, places.Y, places.C
	local n = places.n
	local near = {}
	for a = 1, n do
		local ids, ds, m = { a }, { 0 }, 1
		local xa, ya, ca = X[a], Y[a], C[a]
		for b = 1, n do
			if b ~= a and C[b] == ca then
				local dx, dy = xa - X[b], ya - Y[b]
				local d = dx * dx + dy * dy
				if m <= K or d < ds[m] then
					local at = m + 1
					while at > 2 and ds[at - 1] > d do
						ds[at], ids[at] = ds[at - 1], ids[at - 1]
						at = at - 1
					end
					ds[at], ids[at] = d, b
					if m <= K then m = m + 1 else ds[m + 1], ids[m + 1] = nil, nil end
				end
			end
		end
		near[a] = ids
		if tick and a % 8 == 0 then tick() end
	end
	return near
end

local LENGTHS = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 100, 150 }
local REVERSE_MAX = 64

-- Moves stretches of the order (kept inside what the chains and the log allow) while that saves time.
-- Stops whose neighbourhood did not change since they last found nothing are not tried again.
function EQ.Improve(inst, t, order, places, tick)
	local n, inP, outP, dlog, preds, succs = inst.n, inst.inP, inst.outP, inst.dlog, inst.preds, inst.succs
	local cap, start = inst.cap, inst.start
	local pos, logBefore, active = {}, {}, {}
	local near = nearLists(places, 12, tick)
	local atIn, atOut = {}, {}
	for s = 1, n do
		local p, q = inP[s], outP[s]
		local li = atIn[p]
		if not li then li = {}; atIn[p] = li end
		li[#li + 1] = s
		local lo = atOut[q]
		if not lo then lo = {}; atOut[q] = lo end
		lo[#lo + 1] = s
		active[s] = true
	end
	logBefore[1] = inst.log0
	for i = 1, n do
		pos[order[i]] = i
		logBefore[i + 1] = logBefore[i] + dlog[order[i]]
	end

	local function reindex(a, b)
		for x = a, b do
			local s = order[x]
			pos[s] = x
			logBefore[x + 1] = logBefore[x] + dlog[s]
		end
	end

	local function wake(a, b)
		for x = (a < 1 and 1 or a), (b > n and n or b) do active[order[x]] = true end
	end

	local function capacityOk(i, j, k)
		local log
		if k > j then
			log = logBefore[i]
			for x = j + 1, k do
				log = log + dlog[order[x]]
				if log > cap then return false end
			end
			for x = i, j do
				log = log + dlog[order[x]]
				if log > cap then return false end
			end
		else
			log = logBefore[k + 1]
			for x = i, j do
				log = log + dlog[order[x]]
				if log > cap then return false end
			end
			for x = k + 1, i - 1 do
				log = log + dlog[order[x]]
				if log > cap then return false end
			end
		end
		return true
	end

	local function applyMove(i, j, k)
		local block, L = {}, j - i + 1
		for x = 0, L - 1 do block[x + 1] = order[i + x] end
		if k > j then
			for x = j + 1, k do order[x - L] = order[x] end
			for x = 1, L do order[k - L + x] = block[x] end
			reindex(i, k)
			wake(i - 2, i + 2)
			wake(k - L - 1, k + 2)
		else
			for x = i - 1, k + 1, -1 do order[x + L] = order[x] end
			for x = 1, L do order[k + x] = block[x] end
			reindex(k + 1, j)
			wake(k - 1, k + L + 2)
			wake(j - 2, j + 2)
		end
	end

	local function tryBlock(i, L)
		local j = i + L - 1
		if j > n then return false end
		local a = i > 1 and outP[order[i - 1]] or start
		local b1, b2 = inP[order[i]], outP[order[j]]
		local c = j < n and inP[order[j + 1]] or nil
		local gain = t(a, b1)
		if c then gain = gain + t(b2, c) - t(a, c) end
		if gain <= 0.01 then return false end
		local lo, hi = 0, n + 1
		for x = i, j do
			local s = order[x]
			local list = preds[s]
			for y = 1, #list do
				local w = pos[list[y]]
				if w < i and w > lo then lo = w end
			end
			list = succs[s]
			for y = 1, #list do
				local w = pos[list[y]]
				if w > j and w < hi then hi = w end
			end
		end
		local best, bk = -0.01, nil
		local nb = near[b1]
		for u = 1, #nb do
			local list = atOut[nb[u]]
			if list then
				for v = 1, #list do
					local k = pos[list[v]]
					if k >= lo and k < hi and (k < i - 1 or k > j) then
						local prev = outP[order[k]]
						local nx = k < n and inP[order[k + 1]] or nil
						local add = t(prev, b1)
						if nx then add = add + t(b2, nx) - t(prev, nx) end
						local delta = add - gain
						if delta < best and capacityOk(i, j, k) then best, bk = delta, k end
					end
				end
			end
		end
		nb = near[b2]
		for u = 1, #nb do
			local list = atIn[nb[u]]
			if list then
				for v = 1, #list do
					local k = pos[list[v]] - 1
					if k >= lo and k < hi and (k < i - 1 or k > j) then
						local prev = k >= 1 and outP[order[k]] or start
						local nx = inP[order[k + 1]]
						local add = t(prev, b1) + t(b2, nx) - t(prev, nx)
						local delta = add - gain
						if delta < best and capacityOk(i, j, k) then best, bk = delta, k end
					end
				end
			end
		end
		if not bk then return false end
		applyMove(i, j, bk)
		return true
	end

	local function tryReverse(i, L)
		local j = i + L - 1
		if j > n then return false end
		local a = i > 1 and outP[order[i - 1]] or start
		local first, last = order[i], order[j]
		local c = j < n and inP[order[j + 1]] or nil
		local delta = t(a, inP[last]) - t(a, inP[first])
		if c then delta = delta + t(outP[first], c) - t(outP[last], c) end
		if delta > -0.01 then return false end
		for x = i, j - 1 do
			delta = delta + t(outP[order[x + 1]], inP[order[x]]) - t(outP[order[x]], inP[order[x + 1]])
		end
		if delta > -0.01 then return false end
		for x = i, j do
			local list = preds[order[x]]
			for y = 1, #list do
				local w = pos[list[y]]
				if w >= i and w <= j then return false end
			end
		end
		local log = logBefore[i]
		for x = j, i, -1 do
			log = log + dlog[order[x]]
			if log > cap then return false end
		end
		local lo, hi = i, j
		while lo < hi do
			order[lo], order[hi] = order[hi], order[lo]
			lo, hi = lo + 1, hi - 1
		end
		reindex(i, j)
		wake(i - 2, j + 2)
		return true
	end

	local spent = false
	local function descend()
		local improved = true
		while improved do
			improved = false
			for i = 1, n do
				local s = order[i]
				if active[s] then
					active[s] = false
					for li = 1, #LENGTHS do
						local L = LENGTHS[li]
						if tryBlock(i, L) then improved = true; break end
						if L > 1 and L <= REVERSE_MAX and tryReverse(i, L) then improved = true; break end
						if tick and tick() then spent = true; return end
					end
				end
			end
		end
	end

	local function cost()
		local c, cur = 0, start
		for i = 1, n do
			local s = order[i]
			c = c + t(cur, inP[s])
			cur = outP[s]
		end
		return c
	end

	descend()
	if spent or n < 8 then return order end

	-- Then small shake-ups: a stretch goes next to a nearby place, the moves tidy around it, and the
	-- result stays only if the whole route got shorter. A fixed seed: the same route every time.
	local seed = 12345
	local function random(m)
		seed = (seed * 16807) % 2147483647
		return seed % m + 1
	end
	local best = cost()
	local keep = {}
	for i = 1, n do keep[i] = order[i] end
	while not spent do
		local moved = 0
		for _ = 1, 3 do
			local L = random(24)
			local i = random(n)
			local j = i + L - 1
			if j <= n then
				local lo, hi = 0, n + 1
				for x = i, j do
					local s = order[x]
					local list = preds[s]
					for y = 1, #list do
						local w = pos[list[y]]
						if w < i and w > lo then lo = w end
					end
					list = succs[s]
					for y = 1, #list do
						local w = pos[list[y]]
						if w > j and w < hi then hi = w end
					end
				end
				local nb = near[inP[order[i]]]
				local list = atOut[nb[random(#nb)]]
				if list then
					local k = pos[list[random(#list)]]
					if k >= lo and k < hi and (k < i - 1 or k > j) and capacityOk(i, j, k) then
						applyMove(i, j, k)
						moved = moved + 1
					end
				end
			end
		end
		if moved > 0 then
			descend()
			local c = cost()
			if c < best - 0.01 then
				best = c
				for i = 1, n do keep[i] = order[i] end
			else
				for i = 1, n do
					order[i] = keep[i]
					active[keep[i]] = false
				end
				reindex(1, n)
			end
		end
		if tick and tick() then spent = true end
	end
	for i = 1, n do order[i] = keep[i] end
	return order
end
