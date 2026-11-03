-- Every Quest in the game. Nothing happens by itself at login: the player opens the route's guide in Polestar, and
-- the guide window offers to compute it and to choose which quests it holds (Options.lua; `/everyquest` opens the
-- same choices). The route is computed a few milliseconds per frame under a progress bar, so the game does not stutter, then registered with Polestar
-- as a guide and opened. It is saved: a /reload or a new session finds it again without computing it anew.

local EQ = PolestarEveryQuest
local L = EQ.L
local ROUTE_ID = "every-quest/route"
EQ.ROUTE_ID = ROUTE_ID
local PACK_ID = "every-quest"
local SLICE_MS = 6
-- How long a route takes on the clock. At 6 ms a frame and 60 frames a second that is about 20 s of
-- computing, which comes within 3-5% of what five minutes of it find (tests/bench.lua).
local DEFAULT_SECONDS = 60
-- Group and dungeon quests up to this level are in the route: a level 60 should manage them alone.
local DEFAULT_GROUP_LEVEL = 45
local LOG_CAP = 38 -- the game's log holds 40: room for what the player picks up on the way

local function db()
	PolestarEveryQuestDB = PolestarEveryQuestDB or {}
	local d = PolestarEveryQuestDB
	if d.groupLevel == nil then d.groupLevel = DEFAULT_GROUP_LEVEL end
	if d.seconds == nil then d.seconds = DEFAULT_SECONDS end
	if d.events == nil then d.events = {} end
	return d
end
EQ.DB = db

local function say(text)
	Polestar.Print("Every Quest: " .. text)
end

local function now()
	return debugprofilestop and debugprofilestop() or os.clock() * 1000
end

local function playerInfo()
	local _, class = UnitClass("player")
	local _, race = UnitRace("player")
	return { class = class, race = race, faction = UnitFactionGroup("player"), level = UnitLevel("player") }
end

local function questsInLog()
	if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
		local entries, quests = C_QuestLog.GetNumQuestLogEntries()
		return quests or entries or 0
	end
	if GetNumQuestLogEntries then
		local entries, quests = GetNumQuestLogEntries()
		return quests or entries or 0
	end
	return 0
end

-- What the window chose, as Plan.lua reads it.
local function chosen()
	local d = db()
	local events = {}
	for _, e in ipairs(EQ.EVENTS) do
		if d.events[e.key] then
			for _, id in ipairs(e.ids) do events[id] = true end
		end
	end
	return { pvp = d.pvp, raid = d.raid, events = events, grindRep = d.grindRep }
end

-- The character as Plan.lua reads it.
local function environment()
	local C = Polestar.Compat
	local player = playerInfo()
	local Guides = Polestar.Guides
	local c, x, y = C.GetPlayerWorldPosition()
	if not c then
		-- In an instance or a loading screen, where the game gives no position: the network's first node.
		local n = PolestarEveryQuestMeta.net.nodes[1]
		c, x, y = n[1], n[2], n[3]
	end
	return {
		done = function(q) return C.IsQuestCompleted(q) end,
		inLog = function(q) return C.IsOnQuest(q) end,
		applies = function(step) return Guides.Matches(step.only, player) end,
		toWorld = C.MapToWorld,
		level = player.level or 60,
		logCount = questsInLog(),
		start = { c, x, y },
		groupLevel = db().groupLevel,
		reputationOk = function(faction, needed)
			local _, earned = C.GetFactionStanding(faction)
			return earned ~= nil and earned >= needed
		end,
		cap = LOG_CAP,
		include = chosen(),
	}
end
EQ.Environment = environment

-- The game's own words for what the route names, in its language.
function EQ.FactionName(id)
	local N = Polestar.Names
	return N and N.Faction and N.Faction(id) or nil
end
function EQ.StandingName(standing)
	return _G["FACTION_STANDING_LABEL" .. standing]
end

-- The guide Polestar shows: the catalog's names and texts, the route's steps.
local namesCache, writtenCache
local function routeDef(steps, why)
	-- The guide with no route is registered before a faction's catalog is in use, and needs no names.
	if not namesCache and EQ.catalog[1] then
		namesCache, writtenCache = {}, {}
		for _, def in ipairs(EQ.catalog) do
			for k, v in pairs(def.names or {}) do namesCache[k] = v end
			for k, v in pairs(def.written or {}) do writtenCache[k] = v end
		end
	end
	local zone, zoneName
	for _, s in ipairs(steps) do
		for _, g in ipairs(s.goals) do
			if g.map and not zone then
				zone = g.map
				zoneName = Polestar.Compat.MapName and Polestar.Compat.MapName(g.map) or nil
			end
		end
		if zone then break end
	end
	return {
		id = ROUTE_ID,
		pack = PACK_ID,
		title = L["Every Quest: your route"],
		-- No faction: the addon is for both, and Polestar would show this character's as if the addon were for it alone.
		why = why,
		minLevel = 60,
		maxLevel = 60,
		category = "Miscellaneous",
		zone = zone,
		zoneName = zoneName,
		author = "Bmagic",
		version = 1,
		names = namesCache,
		written = writtenCache,
		steps = steps,
	}
end

-- A tab holds the steps it opened with: Polestar takes new ones when it opens again, here in the same place.
local function reopenTab(i, activate)
	local E = Polestar.Engine
	E.CloseTab(i)
	local index = E.OpenTab(ROUTE_ID, activate)
	if index and index ~= i and E.MoveTab then E.MoveTab(index, i) end
	return index ~= nil
end

-- Polestar calls a pack that holds no guide once its files are in broken, and refuses it from then on. So the
-- route's guide is there from the start, saying what to do, until a computed route replaces it.
local HOW = L["Type /everyquest to choose your quests and compute your route."]
local function placeholder()
	return routeDef({ { title = L["Compute your route"], goals = { { t = "note", text = HOW } } } }, HOW)
end

local function openRoute()
	local E = Polestar.Engine
	for i, t in ipairs(E.GetTabs()) do
		if t.guideId == ROUTE_ID then return reopenTab(i, true) end
	end
	if E.OpenTab(ROUTE_ID, true) then return true end
	return E.SetGuide(ROUTE_ID) and true or false
end

-- What Polestar keeps of this guide by step number: ticks, skips, the step on screen, and the steps' keys. Another
-- route's numbers mean nothing, and matching 2000 steps against 2000 to carry them over holds the game up for half a
-- second. Nothing here is the player's quests: those stay with the game.
local function forgetProgress()
	local state = Polestar.CharState and Polestar.CharState()
	if type(state) ~= "table" then return end
	for _, field in ipairs({ "manual", "skipped", "when", "pins", "shapes", "stepKeys" }) do
		if type(state[field]) == "table" then state[field][ROUTE_ID] = nil end
	end
end

local function publish(result)
	local steps, groups = EQ.WriteRoute(result)
	local ok, err = Polestar.RegisterGuide(routeDef(steps))
	if not ok then
		say(L["the route was refused by Polestar: %s"]:format(tostring(err)))
		return false
	end
	forgetProgress()
	local d = db()
	d.route = groups
	d.routeSteps = #steps
	d.build = PolestarEveryQuestMeta.build
	d.faction = EQ.faction
	if EQ.OptionsChanged then EQ.OptionsChanged() end
	return true
end

-- The saved route, from its catalog references.
local function restore()
	local d = db()
	if type(d.route) ~= "table" or #d.route == 0 then return end
	if not EQ.UseFaction(EQ.PlayerFaction() or d.faction) then return end
	-- A route points at the catalog's steps by number: one from another build of the catalog means nothing.
	if d.build ~= PolestarEveryQuestMeta.build then
		d.route, d.routeSteps, d.build = nil, nil, nil
		return
	end
	local steps = EQ.StepsFromGroups(d.route)
	if #steps > 0 then Polestar.RegisterGuide(routeDef(steps)) end
end

local function describe(info)
	local c = info.counts
	return (L["%d quests to do%s. Left out for now: %d group or dungeon quests above level %d, %d raid, %d PvP, %d seasonal, %d waiting on a reputation, %d above your level."]):format(
		info.quests, (info.grinds and info.grinds > 0) and (L[" and %d reputations to grind"]):format(info.grinds) or "", c.group, db().groupLevel, c.raid, c.pvp, c.season, c.reputation, c.level)
end

---------------------------------------------------------------------------
-- The progress bar
---------------------------------------------------------------------------

local bar
local control = {} -- what the bar's buttons do while a route is being computed

local function progressBar()
	if bar then return bar end
	local Theme, W = Polestar.Theme, Polestar.Widgets
	local f = CreateFrame("Frame", "PolestarEveryQuestProgress", UIParent)
	f:SetSize(340, 96)
	f:SetPoint("TOP", UIParent, "TOP", 0, -140)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	Theme.Skin(f, "window")
	local title = W.Text(f, "label", "text")
	title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
	title:SetText(L["Every Quest: computing your route"])

	local status = CreateFrame("StatusBar", nil, f)
	status:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
	status:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
	status:SetHeight(16)
	status:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	status:SetStatusBarColor(Theme.Accent())
	status:SetMinMaxValues(0, 1)
	status:SetValue(0)
	local back = status:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints(status)
	back:SetColorTexture(0, 0, 0, 0.4)
	local text = W.Text(status, "caption", "text")
	text:SetPoint("CENTER", status, "CENTER", 0, 0)

	local finish = W.Button(f, L["Finish now"], function() if control.finish then control.finish() end end, { primary = true, width = 110 })
	finish:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
	local cancel = W.Button(f, L["Cancel"], function() if control.cancel then control.cancel() end end, { width = 90 })
	cancel:SetPoint("RIGHT", finish, "LEFT", -6, 0)

	f.status, f.text, f.Finish, f.Cancel = status, text, finish, cancel
	f:Hide()
	bar = f
	return f
end

local function showProgress(share, secondsLeft)
	local f = progressBar()
	if share > 1 then share = 1 end
	f.status:SetValue(share)
	f.text:SetText((L["%d%%  -  about %d s left, play on meanwhile"]):format(share * 100, secondsLeft > 0 and secondsLeft or 0))
	if not f:IsShown() then f:Show() end
end

---------------------------------------------------------------------------
-- Computing a route
---------------------------------------------------------------------------

local running = false
local frame

-- A character with no faction yet has no quests here.
function EQ.ForThisCharacter()
	return EQ.UseFaction(EQ.PlayerFaction())
end
EQ.NO_FACTION = L["no quests for this character until it has a faction."]

-- opts.sync, opts.ticks: for tests, no frames and a fixed amount of work instead of a time budget.
function EQ.Plan(opts)
	opts = opts or {}
	if running then
		say(L["already computing your route."])
		return false
	end
	if not EQ.ForThisCharacter() then
		say(EQ.NO_FACTION)
		return false
	end
	local env = environment()
	local inst, places, info = EQ.BuildInstance(env)
	if inst.n == 0 and not info.late then
		say(L["nothing left to do."] .. " " .. describe(info))
		return false
	end
	local seconds = opts.seconds or db().seconds
	local startedAt = now()
	local stopAt = startedAt + seconds * 1000
	local sliceStart = startedAt
	local sync = opts.sync
	-- A tick for a part of the route: share, of the whole time, by when that part is over.
	local function makeTick(share)
		local partEnd = startedAt + seconds * 1000 * share
		local ticks = 0
		return function()
			ticks = ticks + 1
			if sync then return ticks >= (opts.ticks or 20000) end
			local t = now()
			if t - sliceStart >= SLICE_MS then
				coroutine.yield()
				t = now()
				sliceStart = t
			end
			return t >= stopAt or t >= partEnd
		end
	end
	local function work()
		local result = EQ.Solve(inst, places, info, makeTick)
		local hours = result.seconds / 3600
		if publish(result) then
			openRoute()
			say((L["your route is ready, about %.1f h of travel. %s"]):format(hours, describe(info)))
		end
	end
	if sync then
		work()
		return true
	end

	running = true
	local co = coroutine.create(work)
	frame = frame or CreateFrame("Frame")
	local function stop()
		running = false
		control.finish, control.cancel, control.stop = nil, nil, nil
		frame:SetScript("OnUpdate", nil)
		progressBar():Hide()
	end
	control.stop = stop
	control.finish = function() stopAt = now() end
	control.cancel = function()
		stop()
		say(L["route not computed. /everyquest starts it again."])
	end
	showProgress(0, seconds)
	frame:SetScript("OnUpdate", function()
		sliceStart = now()
		local ok, err = coroutine.resume(co)
		if not ok then
			stop()
			say(L["the route could not be computed: %s"]:format(tostring(err)))
		elseif coroutine.status(co) == "dead" then
			stop()
		else
			local t = now()
			showProgress((t - startedAt) / (seconds * 1000), math.ceil((stopAt - t) / 1000))
		end
	end)
	return true
end

function EQ.IsComputing() return running end

-- Back to no route, as on a character that never computed one. A route on its way would come back, so it stops too.
-- An open tab stays where it is, and says there is no route; the active tab stays the active tab.
function EQ.ClearRoute()
	local stopped = control.stop ~= nil
	if stopped then control.stop() end
	local d = db()
	if not d.route then
		say(stopped and L["route not computed. /everyquest starts it again."] or L["no route to clear."])
		return false
	end
	local ok, err = Polestar.RegisterGuide(placeholder())
	if not ok then
		say(L["the route could not be cleared: %s"]:format(tostring(err)))
		return false
	end
	d.route, d.routeSteps, d.build = nil, nil, nil
	forgetProgress()
	local E = Polestar.Engine
	for i, t in ipairs(E.GetTabs()) do
		if t.guideId == ROUTE_ID then
			local open = E.GetGuide()
			reopenTab(i, open ~= nil and open.id == ROUTE_ID)
			break
		end
	end
	if EQ.OptionsChanged then EQ.OptionsChanged() end
	say(L["your route is cleared, your quests are not touched. Compute a new one from the guide window or with /everyquest."])
	return true
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function command(msg)
	local word, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	word = (word or ""):lower()
	if word == "" or word == "options" then
		EQ.ShowOptions()
	elseif word == "compute" then
		EQ.Plan()
	elseif word == "clear" then
		EQ.ClearRoute()
	elseif word == "open" then
		if db().route and openRoute() then
			say(L["your route is open."])
		else
			say(L["no route yet: /everyquest chooses your quests and computes it."])
		end
	elseif word == "status" then
		if EQ.ForThisCharacter() then
			local _, _, info = EQ.BuildInstance(environment())
			say(describe(info))
		else
			say(EQ.NO_FACTION)
		end
	elseif word == "group" then
		local n = tonumber(rest)
		if n and n >= 0 and n <= 60 then
			db().groupLevel = n
			say((L["group and dungeon quests up to level %d count; /everyquest compute computes the route again."]):format(n))
		else
			say((L["group <level>: the highest quest level of the group and dungeon quests in your route (now %d)."]):format(db().groupLevel))
		end
	elseif word == "seconds" then
		local n = tonumber(rest)
		if n and n >= 1 and n <= 600 then
			db().seconds = n
			say((L["the route takes about %d seconds to compute."]):format(n))
		else
			say((L["seconds <n>: how long the route may take to compute (now %d)."]):format(db().seconds))
		end
	else
		say(L["/everyquest: choose your quests and compute your route. /everyquest compute: compute it now. /everyquest open: open it. /everyquest clear: forget it. /everyquest status: what is left. /everyquest group <level>, /everyquest seconds <n>."])
	end
end
EQ.Command = command

SLASH_POLESTAREVERYQUEST1 = "/everyquest"
SlashCmdList = SlashCmdList or {}
SlashCmdList.POLESTAREVERYQUEST = command
if Polestar.RegisterCommand then Polestar.RegisterCommand("everyquest", command, L["Every Quest: choose your quests and compute your route"]) end

Polestar.RegisterGuide(placeholder())

-- SavedVariables are in at this addon's ADDON_LOADED; Polestar reopens its tabs later, at login.
local ADDON = ...
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
	if name == ADDON then
		loader:UnregisterEvent("ADDON_LOADED")
		restore()
	end
end)
