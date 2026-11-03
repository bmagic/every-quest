-- How good a route the planner finds with the time it has in game. Lua 5.1, the game's own language.
--   lua5.1 tests/bench.lua dist/PolestarPack_EveryQuest tests/histories.lua [seconds,...] [only label]
-- BENCH_FACTION=Alliance: a Human Warrior from the network's first point. The histories are the Horde's, so only
-- "nothing done" means anything there.
local dir, historiesFile = arg[1], arg[2]
local checkpoints = {}
for s in (arg[3] or "2,5,15,30,60,180"):gmatch("%d+") do checkpoints[#checkpoints + 1] = tonumber(s) end
local onlyLabel = arg[4]

local frames = {}
Polestar = {
	RegisterPack = function() end,
	RegisterMapFrames = function(t) frames = t end,
}
local function load(file, ...)
	local f = assert(loadfile(dir .. "/" .. file))
	return f("PolestarPack_EveryQuest", {})
end
for _, f in ipairs({ "Data.lua", "Core.lua", "Plan.lua", "MapFrames.lua", "Meta-Horde.lua", "Meta-Alliance.lua", "Catalog-Horde.lua", "Catalog-Alliance.lua" }) do load(f) end
local EQ = PolestarEveryQuest
local FACTION = os.getenv("BENCH_FACTION") or "Horde"
assert(EQ.UseFaction(FACTION))

local function toWorld(map, x, y, f)
	local b = (f == "e" and frames.era and frames.era[map]) or (frames.forever and frames.forever[map]) or (frames.era and frames.era[map]) or frames[map]
	if not b then return nil end
	return b.c, b.top + (b.bottom - b.top) * y / 100, b.left + (b.right - b.left) * x / 100
end

local RACE, CLASS = FACTION == "Alliance" and "Human" or "Orc", "WARRIOR"
local function has(list, v)
	if not list then return true end
	for _, x in ipairs(list) do
		if x == v then return true end
	end
	return false
end
local function applies(step)
	local o = step.only
	if not o then return true end
	return has(o.classes, CLASS) and has(o.races, RACE)
end

-- Orgrimmar's flight master: the first node on Kalimdor in Orgrimmar's walls.
local start = { 1, 1676.9, -4313.2 }
if FACTION == "Alliance" then
	local n = PolestarEveryQuestMeta.net.nodes[1]
	start = { n[1], n[2], n[3] }
end

local histories = dofile(historiesFile)
for _, h in ipairs(histories) do
	if not onlyLabel or h.label:find(onlyLabel, 1, true) then
		local done = {}
		for _, q in ipairs(h.done) do done[q] = true end
		local t0 = os.clock()
		local inst, places, info = EQ.BuildInstance({
			done = function(q) return done[q] end,
			inLog = function() return false end,
			applies = applies,
			toWorld = toWorld,
			level = 60,
			logCount = 0,
			start = start,
			groupLevel = 45,
			reputationOk = function() return true end,
			cap = 38,
		})
		local built = os.clock() - t0
		t0 = os.clock()
		local t = EQ.NewTravel(places, PolestarEveryQuestMeta.net)
		local travel = os.clock() - t0
		t0 = os.clock()
		local order = EQ.Construct(inst, t)
		local constructed = os.clock() - t0
		local greedy = EQ.Cost(inst, t, order)
		io.write(string.format("\n%s: %d done, %d quests, %d stops, %d places (left out: closed %d, group %d, unplaced %d)\n", h.label, #h.done, info.quests, inst.n, places.n, info.counts.closed, info.counts.group, info.counts.unplaced))
		io.write(string.format("  CPU: list %.2f s, travel table %.2f s, first order %.2f s -> %.1f h\n", built, travel, constructed, greedy / 3600))
		local started = os.clock()
		local nextIdx = 1
		local stopAt = checkpoints[#checkpoints]
		local count = 0
		local co = coroutine.wrap(function()
			EQ.Improve(inst, t, order, places, function()
				count = count + 1
				if count % 64 == 0 then
					local e = os.clock() - started
					if nextIdx <= #checkpoints and e >= checkpoints[nextIdx] then
						coroutine.yield("mark")
					end
					if e >= stopAt then return true end
				end
				return false
			end)
			return "done"
		end)
		local report = {}
		while true do
			local r = co()
			local e = os.clock() - started
			local cost = EQ.Cost(inst, t, order)
			if r == "mark" then
				report[#report + 1] = string.format("%ds %.1f h", checkpoints[nextIdx], cost / 3600)
				nextIdx = nextIdx + 1
			else
				report[#report + 1] = string.format("ended at %.0fs: %.1f h", e, cost / 3600)
				break
			end
		end
		io.write("  improved: " .. table.concat(report, " | ") .. "\n")
		-- The order must keep the chains.
		local pos = {}
		for i = 1, inst.n do pos[order[i]] = i end
		local broken = 0
		for s = 1, inst.n do
			for _, p in ipairs(inst.preds[s]) do
				if pos[p] > pos[s] then broken = broken + 1 end
			end
		end
		local log, peak = 0, 0
		for i = 1, inst.n do
			log = log + inst.dlog[order[i]]
			if log > peak then peak = log end
		end
		local steps = EQ.WriteSteps(inst, order, info)
		io.write(string.format("  check: %d chain orders broken, peak log %d, %d guide steps; memory %.0f MiB\n", broken, peak, #steps, collectgarbage("count") / 1024))
	end
end
