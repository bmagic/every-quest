-- Which quests a character is offered, rule by rule, from reports in the game. Plain Lua 5.1.
--   lua5.1 tests/rules.lua dist/PolestarPack_EveryQuest
local dir = arg[1]
local frames = {}
Polestar = { RegisterPack = function() end, RegisterMapFrames = function(t) frames = t end }
for _, f in ipairs({ "Data.lua", "Core.lua", "Plan.lua", "MapFrames.lua", "Meta-Horde.lua", "Meta-Alliance.lua", "Catalog-Horde.lua", "Catalog-Alliance.lua" }) do assert(loadfile(dir .. "/" .. f))("PolestarPack_EveryQuest", {}) end
local EQ = PolestarEveryQuest
assert(EQ.UseFaction("Horde", true))
local function toWorld(map, x, y, f)
	local b = (f == "e" and frames.era and frames.era[map]) or (frames.forever and frames.forever[map]) or (frames.era and frames.era[map])
	if not b then return nil end
	return b.c, b.top + (b.bottom - b.top) * y / 100, b.left + (b.right - b.left) * x / 100
end
local function has(list, v) if not list then return true end for _, x in ipairs(list) do if x == v then return true end end return false end
local function plan(o)
	o = o or {}
	local done = {}
	for _, q in ipairs(o.done or {}) do done[q] = true end
	local inst, places, info = EQ.BuildInstance({
		done = function(q) return done[q] end,
		inLog = function(q) return o.inLog ~= nil and o.inLog[q] == true end,
		applies = function(step) local w = step.only; if not w then return true end return has(w.classes, o.class or "WARRIOR") and has(w.races, o.race or "Orc") end,
		toWorld = toWorld, level = o.level or 60, logCount = 0, start = { 1, 1676.9, -4313.2 }, groupLevel = o.groupLevel or 45,
		reputationOk = o.rep or function() return true end, cap = 38, include = o.include,
	})
	local quests = {}
	local logs = PolestarEveryQuestMeta.steps
	local function read(list)
		for _, stop in ipairs(list) do
			for _, step in ipairs(stop) do
				local ref = EQ.refOf[step]
				if ref then
					local g, i = math.floor(ref / 65536), ref % 65536
					quests[logs[EQ.catalog[g].id][i][1]] = true
				end
			end
		end
	end
	read(info.stopSteps)
	if info.lateSteps then read(info.lateSteps) end
	return quests, info, inst, places
end
local failed = 0
local function check(name, ok)
	if not ok then failed = failed + 1 end
	print((ok and "ok   " or "FAIL ") .. name)
end
local meta = PolestarEveryQuestMeta.quests

-- Reported: Outrider Basic Care Package needs Friendly with the Warsong Outriders.
check("the battlegrounds' care packages are PvP", meta[7866].kind == "pvp" and meta[7867].kind == "pvp")
-- Reported: a quest needing Friendly was offered to a character who is not. A quest of the Magram Clan.
local gated
for id, m in pairs(meta) do
	for _, r in ipairs(m.reps or {}) do
		if r[1] == 93 and r[2] == 3000 and not (m.all and #m.all > 0) and not (m.any and #m.any > 0) then gated = id end
	end
end
check("there is a quest needing Friendly to test with", gated ~= nil)
local all = plan()
local without, info = plan({ rep = function() return false end })
check("a quest needing a reputation stays while the character has it", all[gated] == true)
check("a quest needing a reputation goes while the character has not", without[gated] == nil and info.counts.reputation > 0)
local friendly = plan({ rep = function(_, needed) return needed <= 3000 end })
check("Friendly is enough for a quest needing Friendly", friendly[gated] == true)
local neutral = plan({ rep = function(_, needed) return needed < 3000 end })
check("Neutral is not", neutral[gated] == nil)
-- Reported: The New Horde was not offered. Its follow-up done closes it.
check("The New Horde is on the list with nothing done", plan()[787] == true)
check("The New Horde goes once Cutting Teeth is done", plan({ done = { 788 } })[787] == nil)
-- Reported: Shrouded in Nightmare takes a raid: it starts from an item only the world's dragons drop.
check("a quest needing a world boss's item is raid content", meta[8446] ~= nil and meta[8446].kind == "raid")
check("it stays out whatever the group level, unless raids are chosen", plan({ groupLevel = 60 })[8446] == nil and plan({ include = { raid = true } })[8446] == true)
-- Group and raid are two choices.
do
	local raid
	for id, m in pairs(meta) do
		if m.kind == "raid" and not m.all and not m.any and not m.reps and not m.event and not m.crumbs and (not raid or id < raid) then raid = id end
	end
	check("there is a raid quest to test with", raid ~= nil)
	local _, infoOff = plan()
	check("raid quests are out by default, and counted", plan()[raid] == nil and infoOff.counts.raid > 0)
	check("choosing raids brings them in, even with group quests off", plan({ groupLevel = 0, include = { raid = true } })[raid] == true)
	check("all the group quests do not bring them in", plan({ groupLevel = 60 })[raid] == nil)
	check("not chosen, a raid quest stays out even in the log", plan({ inLog = { [raid] = true } })[raid] == nil)
	local onlyRaid = plan({ groupLevel = 0, include = { raid = true } })
	check("raids chosen do not bring the group quests in", onlyRaid[96876] == nil)
end
check("friendly leaders are not world bosses: their quests stay", meta[93739] ~= nil and meta[8286] ~= nil and meta[925] ~= nil and meta[5502] ~= nil)
check("group quests off also keeps out a low quest with an elite to kill", plan({ groupLevel = 0 })[96876] == nil and plan()[96876] == true)
-- Reported: the "... from the Front" letters drop only from the Scourge Invasion's mobs.
check("the invasion's letters belong to the event", meta[9299].event == 17 and meta[9295].event == 17 and meta[9304].event == 17)
check("they stay out unless the event is chosen", plan()[9299] == nil and plan({ include = { events = { [17] = true } } })[9299] == true)
-- Reported: the Ritual Totems, in the log at Unfriendly, need Neutral with the Timbermaw to be handed in.
do
	local noRep = function() return false end
	local log = { [8471] = true }
	local q1, info1 = plan({ rep = noRep, inLog = log })
	check("a quest in the log waits for its reputation like any other", q1[8471] == nil and info1.counts.reputation > 0)
	local q2 = plan({ rep = function() return true end, inLog = log })
	check("with the reputation it stays", q2[8471] == true)
	local q3, info3 = plan({ rep = noRep, inLog = log, include = { grindRep = true } })
	check("with grinding on it comes after the reputation", q3[8471] == true and info3.late ~= nil)
end
-- Reported: A Meeting with the Master does not exist.
check("the old database's quests are not in the list", meta[3381] == nil)
check("a promotion's voucher starts no quest in the list", meta[5843] == nil and meta[5844] == nil and meta[5847] == nil)
-- Reported: Ribbons of Sacrifice is won in Warsong Gulch, though the client does not mark it as PvP.
check("battleground quests are PvP, marked or not", meta[8266].kind == "pvp" and meta[8267].kind == "pvp" and meta[8568].kind == "pvp" and meta[98887].kind == "pvp" and meta[9665].kind == "pvp")
check("they stay out unless chosen", plan()[8267] == nil and plan({ include = { pvp = true } })[8267] == true)
check("a quest Polestar lists as out is not in the list", meta[9324] == nil)
-- The window's choices.
local function firstOfEvent(event)
	for id, m in pairs(meta) do
		if m.event == event and not m.reps and not m.all and not m.any then return id end
	end
end
local hallow, love = firstOfEvent(12), firstOfEvent(8)
check("there are seasonal quests to test with", hallow ~= nil and love ~= nil)
local onlyHallow, base = plan({ include = { events = { [12] = true } } }), plan()
local outByDefault, inWhenChosen = true, 0
for id, m in pairs(meta) do
	if m.event == 12 then
		if base[id] then outByDefault = false end
		if onlyHallow[id] then inWhenChosen = inWhenChosen + 1 end
	end
end
check("a seasonal quest stays out unless its event is chosen", outByDefault and inWhenChosen > 0)
local othersOut = true
for id, m in pairs(meta) do
	if m.event and m.event ~= 12 and onlyHallow[id] then othersOut = false end
end
check("choosing one event leaves the others out", othersOut)
-- Every seasonal quest of the list belongs to an event the window offers.
local offered = {}
for _, e in ipairs(EQ.EVENTS) do
	for _, id in ipairs(e.ids) do offered[id] = true end
end
local orphan = {}
for id, m in pairs(meta) do
	if m.event and not offered[m.event] then orphan[#orphan + 1] = id .. " event " .. m.event end
end
check("the window offers every event of the list" .. (#orphan > 0 and (": missing " .. table.concat(orphan, ", ")) or ""), #orphan == 0)
-- Grinding: after everything else, standing then its quests, standing by standing.
do
	local noRep = function() return false end
	local quests, info, inst, places = plan({ rep = noRep, include = { grindRep = true } })
	check("grinding brings the reputation quests in, as a second part", info.late ~= nil and info.grinds > 0 and quests[gated] == true)
	local nowHasIt = false
	for _, stop in ipairs(info.stopSteps) do
		for _, step in ipairs(stop) do
			if step.__ref then nowHasIt = true end
		end
	end
	check("no reputation is ground in the first part", not nowHasIt)
	-- In the second part: each standing before the quests it opens, and the tiers in order.
	local late, lateSteps = info.late, info.lateSteps
	local t = EQ.NewTravel(places, PolestarEveryQuestMeta.net)
	local order = EQ.Construct(late, t)
	local pos = {}
	for i = 1, late.n do pos[order[i]] = i end
	local logs = PolestarEveryQuestMeta.steps
	local standingAt, tiersOk, questsOk = {}, true, true
	for s = 1, late.n do
		local step = lateSteps[s][1]
		if step.__ref then
			local f, v = step.__ref:match("^r:(%d+):(%-?%d+)$")
			f, v = tonumber(f), tonumber(v)
			standingAt[f] = standingAt[f] or {}
			standingAt[f][v] = pos[s]
		end
	end
	for f, byValue in pairs(standingAt) do
		local values = {}
		for v in pairs(byValue) do values[#values + 1] = v end
		table.sort(values)
		for i = 2, #values do
			if byValue[values[i - 1]] > byValue[values[i]] then tiersOk = false end
		end
	end
	for s = 1, late.n do
		local step = lateSteps[s][1]
		local ref = EQ.refOf[step]
		if ref and late.dlog[s] > 0 then
			local g, i = math.floor(ref / 65536), ref % 65536
			local q = logs[EQ.catalog[g].id][i][1]
			for _, r in ipairs(meta[q].reps or {}) do
				local at = standingAt[r[1]] and standingAt[r[1]][r[2]]
				if at and at > pos[s] then
					questsOk = false
					print("  " .. q .. " comes before its standing " .. r[1] .. " " .. r[2])
				end
			end
		end
	end
	check("the standings of a faction come in order", tiersOk)
	check("a standing comes before the quests it opens", questsOk)
end
-- Below level 60: nothing the game would show in red, even where it lets the quest be taken. Washte Pawne is level 25,
-- from level 10.
do
	local low, lowInfo = plan({ level = 10 })
	local highest = 0
	for q in pairs(low) do highest = math.max(highest, meta[q].level or 0) end
	check("a level 10 gets nothing 5 levels or more above it: highest " .. highest, highest < 15 and lowInfo.counts.level > 0)
	check("a quest comes in 4 levels below its own", plan({ level = 20 })[885] == nil and plan({ level = 21 })[885] == true)
	check("too high, a quest stays out even in the log", plan({ level = 10, inLog = { [885] = true } })[885] == nil)
	local _, top = plan()
	check("a level 60 loses nothing to this", top.counts.level == 0)
	-- A chain stops where the character's level does, and goes on once it is higher.
	local first, follow
	for q, m in pairs(meta) do
		if m.kind == "plain" and m.any and #m.any == 1 and not m.all and not m.crumbs and not m.reps and not m.event and not m.excl and (not follow or q < follow) then
			local p = meta[m.any[1]]
			if p and p.kind == "plain" and not p.any and not p.all and not p.crumbs and not p.reps and not p.event and not p.excl and (p.level or 0) >= 10 and (m.level or 0) >= (p.level or 0) + 5 then
				first, follow = m.any[1], q
			end
		end
	end
	check("there is a chain to test with: " .. tostring(first) .. " then " .. tostring(follow), follow ~= nil)
	local at = meta[first].level
	local now = plan({ level = at })
	check("the chain's start is in, its follow-up is not yet", now[first] == true and now[follow] == nil)
	local later = plan({ level = meta[follow].level, done = { first } })
	check("with the start done and the level reached, the follow-up comes in", later[follow] == true)
	-- The route itself: every stop after the ones it needs, with the search's first order and its improved one.
	local inst, places = EQ.BuildInstance({
		done = function() return false end, inLog = function() return false end,
		applies = function(step) local w = step.only; if not w then return true end return has(w.classes, "WARRIOR") and has(w.races, "Orc") end,
		toWorld = toWorld, level = 60, logCount = 0, start = { 1, 1676.9, -4313.2 }, groupLevel = 45,
		reputationOk = function() return true end, cap = 38,
	})
	local t = EQ.NewTravel(places, PolestarEveryQuestMeta.net)
	local function broken(order)
		local pos, bad = {}, 0
		for i = 1, inst.n do pos[order[i]] = i end
		for s = 1, inst.n do
			for _, p in ipairs(inst.preds[s]) do
				if pos[p] > pos[s] then bad = bad + 1 end
			end
		end
		return bad
	end
	local order = EQ.Construct(inst, t)
	check("the first order keeps every chain", broken(order) == 0)
	local ticks = 0
	EQ.Improve(inst, t, order, places, function() ticks = ticks + 1; return ticks > 20000 end)
	check("the improved order keeps every chain", broken(order) == 0)
end
-- The Alliance: its own catalog, with the same rules.
assert(EQ.UseFaction("Alliance", true))
meta = PolestarEveryQuestMeta.quests
check("the Alliance's quests are on its list, the Horde's are not", meta[783] ~= nil and meta[787] == nil)
local human = plan({ race = "Human" })
check("a Human is offered the Human start", human[783] == true)
do
	local count = 0
	for _ in pairs(human) do count = count + 1 end
	check("a Human Warrior has many quests to do: " .. count, count > 800)
	-- A quest for one race only, with nothing before it.
	local nightElf
	for _, def in ipairs(EQ.catalog) do
		for i, step in ipairs(def.steps) do
			local races = step.only and step.only.races
			local q = PolestarEveryQuestMeta.steps[def.id][i][1]
			local m = meta[q]
			if races and #races == 1 and races[1] == "NightElf" and not step.only.classes and not m.all and not m.any and not m.crumbs and not m.excl and m.kind == "plain" and not m.event and not m.reps then nightElf = nightElf or q end
		end
	end
	check("there is a Night Elf quest to test with", nightElf ~= nil)
	check("it is for a Night Elf, not a Human", plan({ race = "NightElf" })[nightElf] == true and human[nightElf] == nil)
	local raid
	for id, m in pairs(meta) do
		if m.kind == "raid" and not m.all and not m.any and not m.reps and not m.event and not m.crumbs and (not raid or id < raid) then raid = id end
	end
	check("raids are a choice on this side too", raid ~= nil and human[raid] == nil and plan({ race = "Human", include = { raid = true } })[raid] == true)
	local first = PolestarEveryQuestMeta.net.nodes[1]
	local inst, places = EQ.BuildInstance({
		done = function() return false end, inLog = function() return false end,
		applies = function(step) local w = step.only; if not w then return true end return has(w.classes, "WARRIOR") and has(w.races, "Human") end,
		toWorld = toWorld, level = 60, logCount = 0, start = { first[1], first[2], first[3] }, groupLevel = 45,
		reputationOk = function() return true end, cap = 38,
	})
	local t = EQ.NewTravel(places, PolestarEveryQuestMeta.net)
	local order = EQ.Construct(inst, t)
	check("its route uses its own transport network", #PolestarEveryQuestMeta.net.nodes > 50 and #PolestarEveryQuestMeta.net.taxi > 100 and #order == inst.n and EQ.Cost(inst, t, order) > 0)
end
print(failed == 0 and "rules: all passed" or ("rules: " .. failed .. " failed"))
os.exit(failed == 0 and 0 or 1)
