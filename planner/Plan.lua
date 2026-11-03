-- Every Quest: what this character has left, as the stops of a route. It reads the game only through
-- `env`, so it runs in tests under plain Lua 5.1.
--
--   PolestarEveryQuest.BuildInstance(env) -> inst, places, info
--     env.done(quest), env.inLog(quest), env.applies(step, goal), env.toWorld(map, x, y, f) -> c, wx, wy,
--     env.level, env.logCount, env.start (c, x, y), env.groupLevel, env.reputationOk(faction, value),
--     env.include = { pvp, raid, events = { [event id] = true }, grindRep }
--   PolestarEveryQuest.Solve(inst, places, info, makeTick) -> result: the route in two parts, what can be done now, then
--     (with grindRep) the reputations to grind and what they open
--   PolestarEveryQuest.WriteRoute(result) -> steps, groups
--   PolestarEveryQuest.OptionCounts(env): how many quests each choice of the options window adds
--
-- A catalog step is one stop of one quest. Data.lua holds the catalog and PolestarEveryQuestMeta of the character's faction.

PolestarEveryQuest = PolestarEveryQuest or {}
local EQ = PolestarEveryQuest

local GRID = 25 -- yards: stops this close are one place

-- The seasonal events a player can choose, in calendar order, by the data's event ids.
EQ.EVENTS = {
	{ key = "lunar", name = "Lunar Festival", ids = { 7 } },
	{ key = "love", name = "Love is in the Air", ids = { 8 } },
	{ key = "children", name = "Children's Week", ids = { 10 } },
	{ key = "midsummer", name = "Midsummer Fire Festival", ids = { 1 } },
	{ key = "harvest", name = "Harvest Festival", ids = { 11 } },
	{ key = "hallow", name = "Hallow's End", ids = { 12 } },
	{ key = "winter", name = "Feast of Winter Veil", ids = { 2, 21 } },
	{ key = "newyear", name = "New Year", ids = { 34 } },
	{ key = "faire", name = "Darkmoon Faire", ids = { 4 } },
	{ key = "scourge", name = "Scourge Invasion", ids = { 17 } },
	{ key = "aq", name = "Ahn'Qiraj War", ids = { 22, 62, 63, 64, 85, 86 } },
}

local STANDING_NAME = { [4] = "Neutral", [5] = "Friendly", [6] = "Honored", [7] = "Revered", [8] = "Exalted" }
local function standingOf(value)
	if value >= 42000 then return 8 end
	if value >= 21000 then return 7 end
	if value >= 9000 then return 6 end
	if value >= 3000 then return 5 end
	return 4
end

-- The step that waits for a standing: Polestar checks it off once the character has it.
local function repStep(faction, value)
	local standing = standingOf(value)
	local name = (PolestarEveryQuestMeta.factions and PolestarEveryQuestMeta.factions[faction]) or ("Faction " .. faction)
	local guide = PolestarEveryQuestMeta.repGuides and PolestarEveryQuestMeta.repGuides[faction]
	return {
		title = ("Reach %s with %s"):format(STANDING_NAME[standing], name),
		__ref = ("r:%d:%d"):format(faction, value),
		goals = { {
			t = "rep", faction = faction, factionName = name, standing = standing,
			note = guide and ("Polestar's guide \"%s\" (Reputation) shows how; the route waits here."):format(guide) or "Grind it your way; the route waits here.",
		} },
	}
end

local function needsReputation(env, m)
	for _, r in ipairs(m.reps or {}) do
		if not env.reputationOk(r[1], r[2]) then return true end
	end
	return false
end

-- Group content: what the client marks so, and any quest with a goal the compiler found to need a group (an
-- elite or a boss to kill, an item only they drop), which the client may call a plain quest. A raid quest has a
-- choice of its own, whatever its level.
local function isGroupQuest(q, m)
	if m.kind == "raid" then return false end
	return m.kind == "group" or m.kind == "dungeon" or (EQ.needsGroup and EQ.needsGroup[q]) == true
end

-- A quest 5 levels or more above the character shows in red in the game: out of reach, even where the game lets it be
-- taken (Washte Pawne, level 25, from level 10).
local RED_LEVELS = 5
local function tooHigh(env, m)
	return (m.level or 0) >= env.level + RED_LEVELS
end

-- The quests that can still be done: not done, for this character, not closed, their chains open.
local function questsLeft(env, stepsOf)
	local meta = PolestarEveryQuestMeta.quests
	local kept, counts = {}, { closed = 0, group = 0, raid = 0, reputation = 0, level = 0, unplaced = 0, season = 0, pvp = 0 }
	local done, inLog = env.done, env.inLog
	local include = env.include or {}
	local chosenEvents = include.events or {}
	local grind = {}
	for q, m in pairs(meta) do
		local stops = stepsOf[q]
		if stops and not done(q) then
			local first = stops[1]
			if env.applies(first.step) then
				-- Not chosen, a raid quest stays out even if it is in the log: the route must not send the player to a raid.
				if m.kind == "raid" and not include.raid then
					counts.raid = counts.raid + 1
				elseif tooHigh(env, m) then
					counts.level = counts.level + 1
				elseif inLog(q) then
					-- Taken already: it stays, but without the standing it cannot be handed in (the Ritual Totems at Unfriendly).
					if not needsReputation(env, m) then
						kept[q] = true
					elseif include.grindRep then
						kept[q] = true
						grind[q] = true
					else
						counts.reputation = counts.reputation + 1
					end
				elseif m.event and not chosenEvents[m.event] then
					counts.season = counts.season + 1
				elseif m.kind == "pvp" and not include.pvp then
					counts.pvp = counts.pvp + 1
				elseif isGroupQuest(q, m) and (m.level or 0) > env.groupLevel then
					counts.group = counts.group + 1
				elseif (first.goal and (tonumber(first.goal.minLevel) or 1) > env.level) or (m.maxLevel and env.level > m.maxLevel) then
					counts.level = counts.level + 1
				elseif needsReputation(env, m) then
					if include.grindRep then
						kept[q] = true
						grind[q] = true
					else
						counts.reputation = counts.reputation + 1
					end
				else
					kept[q] = true
				end
			end
		end
	end

	-- Closed for good: an exclusive sibling or the follow-up of a breadcrumb taken or done.
	local function taken(q) return done(q) or inLog(q) end
	for q in pairs(kept) do
		local m = meta[q]
		if not inLog(q) then
			local closed = false
			for _, x in ipairs(m.excl or {}) do
				if taken(x) then closed = true end
			end
			if m.crumbFor and taken(m.crumbFor) then closed = true end
			-- The follow-up taken or done: the game no longer offers the quest before it.
			if m.nextq and taken(m.nextq) then closed = true end
			if closed then
				kept[q] = nil
				counts.closed = counts.closed + 1
			end
		end
	end

	-- A chain that cannot open goes too.
	local function cascade()
		local changed = true
		while changed do
			changed = false
			for q in pairs(kept) do
				local m = meta[q]
				local ok = inLog(q)
				if not ok then
					ok = true
					for _, p in ipairs(m.all or {}) do
						if not (done(p) or kept[p]) then ok = false end
					end
					if ok and m.any and #m.any > 0 then
						ok = false
						for _, p in ipairs(m.any) do
							if done(p) or kept[p] then ok = true end
						end
					end
				end
				if not ok then
					kept[q] = nil
					counts.closed = counts.closed + 1
					changed = true
				end
			end
		end
	end
	cascade()

	-- Exclusive quests still open: the largest set with no exclusive pair, the ones that open most first.
	local dependents = {}
	for q in pairs(kept) do
		local m = meta[q]
		for _, p in ipairs(m.all or {}) do dependents[p] = (dependents[p] or 0) + 1 end
		for _, p in ipairs(m.any or {}) do dependents[p] = (dependents[p] or 0) + 1 end
	end
	local links = {}
	local function link(a, b)
		links[a] = links[a] or {}
		links[a][b] = true
	end
	for q in pairs(kept) do
		for _, x in ipairs(meta[q].excl or {}) do
			if kept[x] and x ~= q then
				link(q, x)
				link(x, q)
			end
		end
	end
	local seen = {}
	for q in pairs(links) do
		if not seen[q] then
			local comp, stack = {}, { q }
			while #stack > 0 do
				local c = table.remove(stack)
				if not seen[c] then
					seen[c] = true
					comp[#comp + 1] = c
					for o in pairs(links[c]) do stack[#stack + 1] = o end
				end
			end
			table.sort(comp, function(a, b)
				local da, db = dependents[a] or 0, dependents[b] or 0
				if da ~= db then return da > db end
				return a < b
			end)
			local best = {}
			local function go(i, cur)
				if #cur + (#comp - i + 1) <= #best then return end
				if i > #comp then
					best = { unpack(cur) }
					return
				end
				local c = comp[i]
				local free = true
				for _, x in ipairs(cur) do
					if links[c][x] then free = false end
				end
				if free then
					cur[#cur + 1] = c
					go(i + 1, cur)
					cur[#cur] = nil
				end
				go(i + 1, cur)
			end
			go(1, {})
			local keep = {}
			for _, x in ipairs(best) do keep[x] = true end
			for _, c in ipairs(comp) do
				if not keep[c] and not inLog(c) then
					kept[c] = nil
					counts.closed = counts.closed + 1
				end
			end
		end
	end
	cascade()
	for q in pairs(grind) do
		if not kept[q] then grind[q] = nil end
	end
	return kept, counts, grind
end

-- The catalog's steps by quest: { { step, kind, goal } } in catalog order.
local function indexCatalog()
	local stepsOf = {}
	local logs = PolestarEveryQuestMeta.steps
	EQ.refOf = {}
	EQ.needsGroup = {}
	for gi, def in ipairs(EQ.catalog) do
		local log = logs[def.id]
		for i, step in ipairs(def.steps) do
			EQ.refOf[step] = gi * 65536 + i
			local e = log[i]
			local q, kind = e[1], e[2]
			local list = stepsOf[q]
			if not list then
				list = {}
				stepsOf[q] = list
			end
			local goal
			for _, g in ipairs(step.goals) do
				if g.t == "accept" then goal = g end
				if g.group then EQ.needsGroup[q] = true end
			end
			list[#list + 1] = { step = step, kind = kind, goal = goal }
		end
	end
	return stepsOf
end

local function placeOfStep(env, step)
	for _, g in ipairs(step.goals) do
		if g.map and g.x and g.y then
			local c, x, y = env.toWorld(g.map, g.x, g.y, g.f)
			if c then return c, x, y end
		end
	end
	return nil
end

-- The stops of `quests` and the orders between them. `extra`, when given, adds stops of its own.
local function assemble(env, stepsOf, quests, place, start, counts, unplaced, extra)
	local meta = PolestarEveryQuestMeta.quests
	local done, inLog = env.done, env.inLog
	-- A quest walked in one go (an escort, a timed quest) is one stop.
	local inP, outP, dlog, preds, succs, stopSteps = {}, {}, {}, {}, {}, {}
	local n = 0
	local function addStop(pIn, pOut, delta, list)
		n = n + 1
		inP[n], outP[n], dlog[n], preds[n], succs[n], stopSteps[n] = pIn, pOut, delta, {}, {}, list
		return n
	end
	local function edge(a, b)
		preds[b][#preds[b] + 1] = a
		succs[a][#succs[a] + 1] = b
	end
	local firstStop, lastStop = {}, {}
	for q in pairs(quests) do
		local stops = stepsOf[q]
		local onIt = inLog(q)
		-- Each stop's place; one with none shares its neighbour's.
		local located = {}
		local lastP
		for i, st in ipairs(stops) do
			local c, x, y = placeOfStep(env, st.step)
			if c then lastP = place(c, x, y) end
			located[i] = lastP
		end
		local nextP
		for i = #stops, 1, -1 do
			if located[i] then nextP = located[i] else located[i] = nextP end
		end
		if not nextP and not lastP then
			quests[q] = nil
			counts.unplaced = counts.unplaced + 1
			unplaced[#unplaced + 1] = q
		elseif meta[q].tight and not onIt then
			local list = {}
			for _, st in ipairs(stops) do list[#list + 1] = st.step end
			local s = addStop(located[1], located[#stops], 0, list)
			firstStop[q], lastStop[q] = s, s
		else
			local accept
			local works = {}
			for i, st in ipairs(stops) do
				if st.kind == "A" then
					if not onIt then
						accept = addStop(located[i], located[i], 1, { st.step })
						firstStop[q] = accept
					end
				elseif st.kind == "W" then
					local w = addStop(located[i], located[i], 0, { st.step })
					if accept then edge(accept, w) end
					works[#works + 1] = w
					if not firstStop[q] then firstStop[q] = w end
				else
					local t = addStop(located[i], located[i], -1, { st.step })
					if accept and #works == 0 then edge(accept, t) end
					for _, w in ipairs(works) do edge(w, t) end
					lastStop[q] = t
					if not firstStop[q] then firstStop[q] = t end
				end
			end
		end
	end

	-- The chains between quests.
	for q in pairs(quests) do
		local m = meta[q]
		if not inLog(q) then
			local first = firstStop[q]
			for _, p in ipairs(m.all or {}) do
				if lastStop[p] then edge(lastStop[p], first) end
			end
			if m.any and #m.any > 0 then
				local open = false
				for _, p in ipairs(m.any) do
					if done(p) or (not quests[p] and EQ.earlier and EQ.earlier[p]) then open = true end
				end
				if not open then
					local bestP
					for _, p in ipairs(m.any) do
						if lastStop[p] and (not bestP or p < bestP) then bestP = p end
					end
					if bestP then edge(lastStop[bestP], first) end
				end
			end
			for _, c in ipairs(m.crumbs or {}) do
				if lastStop[c] and not inLog(c) then edge(lastStop[c], first) end
			end
		end
	end

	if extra then extra(addStop, edge, firstStop, lastStop, inP, succs) end

	-- A cycle in the data must not hang the route: the edges into what is left over go.
	local left, stack, seen = {}, {}, 0
	for s = 1, n do
		left[s] = #preds[s]
		if left[s] == 0 then stack[#stack + 1] = s end
	end
	while #stack > 0 do
		local s = table.remove(stack)
		seen = seen + 1
		for _, x in ipairs(succs[s]) do
			left[x] = left[x] - 1
			if left[x] == 0 then stack[#stack + 1] = x end
		end
	end
	local function cut(s)
		for _, p in ipairs(preds[s]) do
			local list = succs[p]
			for i = #list, 1, -1 do
				if list[i] == s then table.remove(list, i) end
			end
		end
		preds[s] = {}
	end
	local function unordered()
		local left2, stack2, seen2 = {}, {}, 0
		for s = 1, n do
			left2[s] = #preds[s]
			if left2[s] == 0 then stack2[#stack2 + 1] = s end
		end
		while #stack2 > 0 do
			local s = table.remove(stack2)
			seen2 = seen2 + 1
			for _, x in ipairs(succs[s]) do
				left2[x] = left2[x] - 1
				if left2[x] == 0 then stack2[#stack2 + 1] = x end
			end
		end
		return seen2 < n and left2 or nil
	end
	if seen < n then
		for s = 1, n do
			if left[s] > 0 and dlog[s] > 0 then cut(s) end
		end
		local still = unordered()
		if still then
			for s = 1, n do
				if still[s] > 0 then cut(s) end
			end
		end
	end
	return { n = n, inP = inP, outP = outP, dlog = dlog, preds = preds, succs = succs, start = start, cap = env.cap or 38, log0 = env.logCount or 0 }, stopSteps
end

-- What must wait for a reputation: the quests needing one the character has not yet, and what hangs on them.
local function waitingSet(env, kept, grind)
	local meta = PolestarEveryQuestMeta.quests
	local late = {}
	for q in pairs(grind) do late[q] = true end
	local changed = next(late) ~= nil
	while changed do
		changed = false
		for q in pairs(kept) do
			if not late[q] and not env.inLog(q) then
				local m = meta[q]
				local hangs = false
				for _, p in ipairs(m.all or {}) do
					if late[p] then hangs = true end
				end
				if m.any and #m.any > 0 then
					local open = false
					for _, p in ipairs(m.any) do
						if env.done(p) or (kept[p] and not late[p]) then open = true end
					end
					if not open then hangs = true end
				end
				for _, c in ipairs(m.crumbs or {}) do
					if late[c] then hangs = true end
				end
				if hangs then
					late[q] = true
					changed = true
				end
			end
		end
	end
	return late
end

function EQ.BuildInstance(env)
	local stepsOf = EQ.stepsOf
	if not stepsOf then
		stepsOf = indexCatalog()
		EQ.stepsOf = stepsOf
	end
	local meta = PolestarEveryQuestMeta.quests
	local kept, counts, grind = questsLeft(env, stepsOf)

	-- Places
	local places = { X = {}, Y = {}, C = {}, n = 0 }
	local placeAt = {}
	local function place(c, x, y)
		local key = c * 4096 * 4096 + math.floor(x / GRID + 2048) * 4096 + math.floor(y / GRID + 2048)
		local p = placeAt[key]
		if not p then
			p = places.n + 1
			places.n = p
			places.X[p], places.Y[p], places.C[p] = x, y, c
			placeAt[key] = p
		end
		return p
	end
	local start = place(env.start[1], env.start[2], env.start[3])
	local unplaced = {}

	-- What can be done now first; what waits for a reputation comes after, so a long grind holds nothing up.
	local late = waitingSet(env, kept, grind)
	local now = {}
	for q in pairs(kept) do
		if not late[q] then now[q] = true end
	end
	EQ.earlier = nil
	local inst, stopSteps = assemble(env, stepsOf, now, place, start, counts, unplaced)
	local info = { stopSteps = stopSteps, counts = counts, unplaced = unplaced }
	local questCount = 0
	for _ in pairs(now) do questCount = questCount + 1 end

	if next(late) then
		EQ.earlier = now
		-- A quest's standing in each faction, at least that of the quests before it in its chain: one needing
		-- Friendly that follows one needing Honored belongs with Honored.
		local need = {}
		for q in pairs(late) do
			local own = {}
			for _, r in ipairs(meta[q].reps or {}) do
				if not env.reputationOk(r[1], r[2]) then own[r[1]] = r[2] end
			end
			need[q] = own
		end
		local grew = true
		while grew do
			grew = false
			for q in pairs(late) do
				local m = meta[q]
				local function inherit(p)
					if need[p] then
						for f, v in pairs(need[p]) do
							if not need[q][f] or need[q][f] < v then
								need[q][f] = v
								grew = true
							end
						end
					end
				end
				for _, p in ipairs(m.all or {}) do inherit(p) end
				for _, p in ipairs(m.crumbs or {}) do inherit(p) end
				if m.any and #m.any > 0 then
					local open = false
					for _, p in ipairs(m.any) do
						if env.done(p) or now[p] then open = true end
					end
					if not open then
						for _, p in ipairs(m.any) do
							if late[p] then
								inherit(p)
								break
							end
						end
					end
				end
			end
		end
		local tiers = {}
		for q, byFaction in pairs(need) do
			for f, v in pairs(byFaction) do
				tiers[f] = tiers[f] or {}
				tiers[f][v] = tiers[f][v] or {}
				table.insert(tiers[f][v], q)
			end
		end
		local grinds = 0
		local lateInst, lateSteps = assemble(env, stepsOf, late, place, start, counts, unplaced, function(addStop, edge, firstStop, lastStop, inP, succs)
			-- Does b come after a already? An order that would close a loop is left out.
			local function comesAfter(a, b)
				local stack, seen = { a }, {}
				while #stack > 0 do
					local s = table.remove(stack)
					if s == b then return true end
					if not seen[s] then
						seen[s] = true
						for _, x in ipairs(succs[s]) do stack[#stack + 1] = x end
					end
				end
				return false
			end
			local soft = {}
			for faction, byValue in pairs(tiers) do
				local values = {}
				for v in pairs(byValue) do values[#values + 1] = v end
				table.sort(values)
				local previous, previousQuests
				for _, v in ipairs(values) do
					local list = byValue[v]
					table.sort(list)
					-- It stands where the tier's first quest does: the grind itself is not travel on the route.
					local firstQuest
					for _, q in ipairs(list) do
						if firstStop[q] then
							firstQuest = firstStop[q]
							break
						end
					end
					if firstQuest then
						local at = inP[firstQuest]
						local s = addStop(at, at, 0, { repStep(faction, v) })
						grinds = grinds + 1
						if previous then edge(previous, s) end
						for _, q in ipairs(previousQuests or {}) do
							if lastStop[q] then soft[#soft + 1] = { lastStop[q], s } end
						end
						for _, q in ipairs(list) do
							if firstStop[q] then edge(s, firstStop[q]) end
						end
						previous, previousQuests = s, list
					end
				end
			end
			-- Do a standing's quests before grinding the next one, where the chains allow it: they give reputation too.
			for _, e in ipairs(soft) do
				if not comesAfter(e[2], e[1]) then edge(e[1], e[2]) end
			end
		end)
		EQ.earlier = nil
		for _ in pairs(late) do questCount = questCount + 1 end
		info.late, info.lateSteps, info.grinds = lateInst, lateSteps, grinds
	end
	info.quests = questCount
	return inst, places, info
end

-- The route, part by part. makeTick(share) -> a tick for that share of the time.
function EQ.Solve(inst, places, info, makeTick)
	local t = EQ.NewTravel(places, PolestarEveryQuestMeta.net)
	local share = info.late and 0.8 or 1
	local tick = makeTick and makeTick(share)
	local order = EQ.Construct(inst, t, tick)
	EQ.Improve(inst, t, order, places, tick)
	local result = { inst = inst, order = order, stopSteps = info.stopSteps, seconds = EQ.Cost(inst, t, order) }
	local late = info.late
	if late then
		if inst.n > 0 then late.start = inst.outP[order[inst.n]] end
		local tick2 = makeTick and makeTick(1)
		local order2 = EQ.Construct(late, t, tick2)
		EQ.Improve(late, t, order2, places, tick2)
		result.late, result.lateOrder, result.lateSteps = late, order2, info.lateSteps
		result.seconds = result.seconds + EQ.Cost(late, t, order2)
	end
	return result
end

-- How many quests each choice of the options window concerns, for this character.
function EQ.OptionCounts(env)
	local stepsOf = EQ.stepsOf
	if not stepsOf then
		stepsOf = indexCatalog()
		EQ.stepsOf = stepsOf
	end
	local c = { events = {}, pvp = 0, raid = 0, reputation = 0, group = 0 }
	for q, m in pairs(PolestarEveryQuestMeta.quests) do
		local stops = stepsOf[q]
		if stops and not env.done(q) and env.applies(stops[1].step) and not tooHigh(env, m) then
			if m.event then
				c.events[m.event] = (c.events[m.event] or 0) + 1
			elseif m.kind == "raid" then
				c.raid = c.raid + 1
			elseif m.kind == "pvp" then
				if not (m.maxLevel and env.level > m.maxLevel) then c.pvp = c.pvp + 1 end
			elseif isGroupQuest(q, m) and (m.level or 0) > env.groupLevel then
				c.group = c.group + 1
			elseif needsReputation(env, m) then
				c.reputation = c.reputation + 1
			end
		end
	end
	return c
end

-- Polestar rewrites the texts of a guide it registers, in place: the catalog keeps its own.
local function copied(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copied(x) end
	return out
end

-- The route as guide steps: stops at one place become one step. -> steps, groups (their catalog
-- references, what a character saves).
local MAX_GOALS = 12
function EQ.WriteSteps(inst, order, info)
	local steps, groups = {}, {}
	local cur, curRefs, curOut
	local refOf = EQ.refOf
	for i = 1, inst.n do
		local s = order[i]
		for j, step in ipairs(info.stopSteps[s]) do
			local samePlace = j == 1 and cur and curOut == inst.inP[s]
			if step.__ref or not (samePlace and #cur.goals + #step.goals <= MAX_GOALS) then
				cur, curRefs = { title = step.title, goals = {} }, {}
				steps[#steps + 1] = cur
				groups[#groups + 1] = curRefs
			end
			for _, g in ipairs(step.goals) do cur.goals[#cur.goals + 1] = copied(g) end
			curRefs[#curRefs + 1] = refOf[step] or step.__ref
			curOut = nil
			if step.__ref then cur = nil end
		end
		curOut = cur and inst.outP[s] or nil
	end
	return steps, groups
end

function EQ.WriteRoute(result)
	local steps, groups = EQ.WriteSteps(result.inst, result.order, { stopSteps = result.stopSteps })
	if result.late then
		local s2, g2 = EQ.WriteSteps(result.late, result.lateOrder, { stopSteps = result.lateSteps })
		for i = 1, #s2 do
			steps[#steps + 1] = s2[i]
			groups[#groups + 1] = g2[i]
		end
	end
	return steps, groups
end

-- The saved references back as guide steps.
function EQ.StepsFromGroups(groups)
	if not EQ.stepsOf then
		EQ.stepsOf = indexCatalog()
	end
	local steps = {}
	for _, refs in ipairs(groups) do
		local cur
		for _, ref in ipairs(refs) do
			local step
			if type(ref) == "string" then
				local faction, value = ref:match("^r:(%d+):(%-?%d+)$")
				if faction then step = repStep(tonumber(faction), tonumber(value)) end
			else
				local def = EQ.catalog[math.floor(ref / 65536)]
				step = def and def.steps[ref % 65536]
			end
			if step then
				if not cur then
					cur = { title = step.title, goals = {} }
					steps[#steps + 1] = cur
				end
				for _, goal in ipairs(step.goals) do cur.goals[#cur.goals + 1] = copied(goal) end
			end
		end
	end
	return steps
end
