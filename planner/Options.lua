-- Every Quest's window: which quests the route holds. Built with Polestar's own widgets and theme, so it
-- takes whatever look the player chose there. `/everyquest` opens it; L["Compute my route"] starts the route.

local EQ = PolestarEveryQuest
local L = EQ.L
local Theme, W = Polestar.Theme, Polestar.Widgets

local NAME = "PolestarEveryQuestOptions"
local WIDTH, HEIGHT, PAD, HEAD_H, FOOT_H = 460, 640, 18, 56, 84

local F
local rows = {} -- every setting row, with row.psCount(counts) -> its count when it has one

local function refresh()
	if not F then return end
	local counts, info
	if EQ.ForThisCharacter() then
		local env = EQ.Environment()
		counts = EQ.OptionCounts(env)
		local _
		_, _, info = EQ.BuildInstance(env)
	end
	for _, row in ipairs(rows) do
		if row.psCount and counts then
			local n = row.psCount(counts)
			row.Label:SetText(n > 0 and ("%s  (%d)"):format(row.psName, n) or row.psName)
		end
		if row.Refresh then row:Refresh() end
	end
	if not info then
		F.Total:SetText(L["No quests until this character has a faction"])
		F.Compute:Disable()
	elseif info.grinds and info.grinds > 0 then
		F.Total:SetText((L["%d quests and %d reputations to grind"]):format(info.quests, info.grinds))
		F.Compute:Enable()
	else
		F.Total:SetText((L["%d quests in your route"]):format(info.quests))
		F.Compute:Enable()
	end
	-- Polestar's text buttons look the same when disabled: dimmed as its icon buttons are.
	local hasRoute = EQ.DB().route ~= nil
	if hasRoute then F.Clear:Enable() else F.Clear:Disable() end
	F.Clear:SetAlpha(hasRoute and 1 or 0.35)
end

-- A route came or went while the window is open.
function EQ.OptionsChanged()
	if F and F:IsShown() then refresh() end
end

-- One switch, kept in this character's settings.
local function toggle(parent, key, name, tip, get, set, count)
	local row = W.Toggle(parent, name, "everyquest." .. key, tip, nil, {
		get = get,
		set = function(value)
			set(value and true or false)
			refresh()
		end,
	})
	row.psName, row.psCount = name, count
	rows[#rows + 1] = row
	return row
end

local function section(parent, text, y)
	local h = W.SectionHeader(parent)
	W.SetSection(h, text)
	h:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -y)
	h:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
	return y + h:GetHeight()
end

-- A zone's name as the game writes it in its language.
local function zone(id, english)
	local C = Polestar.Compat
	return C and C.MapName and C.MapName(id) or english
end

local function build()
	local d = EQ.DB()
	F = CreateFrame("Frame", NAME, UIParent)
	F:SetFrameStrata("DIALOG")
	F:SetToplevel(true)
	F:SetClampedToScreen(true)
	F:EnableMouse(true)
	F:SetMovable(true)
	F:SetSize(WIDTH, HEIGHT)
	F:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	F:Hide()
	Theme.Skin(F, "window")
	UISpecialFrames = UISpecialFrames or {}
	table.insert(UISpecialFrames, NAME)

	local head = CreateFrame("Frame", nil, F)
	head:SetPoint("TOPLEFT", F, "TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", F, "TOPRIGHT", -1, -1)
	head:SetHeight(HEAD_H)
	head:EnableMouse(true)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() F:StartMoving() end)
	head:SetScript("OnDragStop", function() F:StopMovingOrSizing() end)
	local band = Theme.Band(head, "BACKGROUND", -5)
	band:SetAllPoints(head)
	band:SetTexCoord(Theme.BandCoords(WIDTH - 2, HEAD_H))
	local close = W.IconButton(head, "close", 28, L["Close"], function() F:Hide() end, 14)
	close:SetPoint("TOPRIGHT", head, "TOPRIGHT", -12, -14)
	local title = W.Text(head, "title", "text")
	title:SetPoint("LEFT", head, "LEFT", PAD, 0)
	title:SetText("Every Quest")

	local scroll = W.Scroll(F)
	scroll:SetPoint("TOPLEFT", F, "TOPLEFT", 1, -(HEAD_H + 1))
	scroll:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", -1, FOOT_H)
	local body = scroll.Child
	body:SetWidth(WIDTH - 2)
	local rowWidth = WIDTH - 2 - PAD * 2
	local y = 4

	local function place(row)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, -y)
		y = y + W.LayoutRow(row, rowWidth)
	end

	y = section(body, L["In your route"], y)
	local group = W.Dropdown(body, L["Group and dungeon quests"], "everyquest.groupLevel", {
		{ value = 0, text = L["None"] },
		{ value = 30, text = L["Up to level %d"]:format(30) },
		{ value = 45, text = L["Up to level %d"]:format(45) },
		{ value = 50, text = L["Up to level %d"]:format(50) },
		{ value = 55, text = L["Up to level %d"]:format(55) },
		{ value = 60, text = L["All of them"] },
	}, L["Quests of the client's group and dungeon kinds, and any quest with an elite or a boss to kill. A level 60 should manage them alone up to level 45. Above that, plan on a group."], nil, {
		get = function() return EQ.DB().groupLevel end,
		set = function(value)
			EQ.DB().groupLevel = value or 45
			refresh()
		end,
	})
	rows[#rows + 1] = group
	place(group)
	place(toggle(body, "raid", L["Raid quests"], L["Quests in a raid, or that need what a world boss drops. They take a raid group, whatever your level."],
		function() return EQ.DB().raid end,
		function(value) EQ.DB().raid = value end,
		function(c) return c.raid end))
	place(toggle(body, "pvp", L["PvP quests"], L["Battleground quests: %s, %s, %s, %s. Marks and reputations come from playing them."]:format(zone(1460, "Warsong Gulch"), zone(1461, "Arathi Basin"), zone(1459, "Alterac Valley"), zone(2524, "Darkspear Islands")),
		function() return EQ.DB().pvp end,
		function(value) EQ.DB().pvp = value end,
		function(c) return c.pvp end))
	place(toggle(body, "grindRep", L["Reputation quests, grinding what they need"],
		L["After the other quests, faction by faction: reach the standing, do the quests it opens, then the next standing, up to the last. Without this, a quest stays out until you have the standing it needs."],
		function() return EQ.DB().grindRep end,
		function(value) EQ.DB().grindRep = value end,
		function(c) return c.reputation end))

	y = section(body, L["Seasonal events"], y + 6)
	local hint = W.Text(body, "note", "textDim")
	hint:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, -y)
	hint:SetWidth(rowWidth)
	hint:SetWordWrap(true)
	hint:SetJustifyH("LEFT")
	hint:SetText(L["Their quests are only offered while the event runs: choose the ones running now."])
	y = y + math.ceil(hint:GetStringHeight()) + 8
	for _, e in ipairs(EQ.EVENTS) do
		place(toggle(body, "event." .. e.key, e.name, nil,
			function() return EQ.DB().events[e.key] end,
			function(value) EQ.DB().events[e.key] = value or nil end,
			function(c)
				local n = 0
				for _, id in ipairs(e.ids) do n = n + (c.events[id] or 0) end
				return n
			end))
	end

	W.SetScrollContent(scroll, y + 12)

	F.Total = W.Text(F, "label", "text")
	F.Total:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", PAD, 54)
	local compute = W.Button(F, L["Compute my route"], function()
		F:Hide()
		EQ.Plan()
	end, { primary = true, width = 170 })
	compute:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", -PAD, 16)
	F.Compute = compute
	-- A second click acts, as on Polestar's own "Reset guide progress". No fixed width: it grows for what the first click says.
	local clear = W.Button(F, L["Clear my route"], nil, { danger = true })
	clear.psSetText = W.SetButtonText
	W.Confirm(clear, L["Clear my route"], function() EQ.ClearRoute() end)
	clear:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", PAD, 16)
	F.Clear = clear
	F.Scroll, F.Rows = scroll, rows
	F:SetScript("OnShow", refresh)
	return d
end

function EQ.ShowOptions()
	if not F then build() end
	if F:IsShown() then
		refresh()
	else
		F:Show()
	end
	return F
end

---------------------------------------------------------------------------
-- The way here from Polestar's own windows. Nothing of Polestar's is changed on disk; these lean on parts of it
-- that are not a promised interface, so each checks they are there: without them /everyquest still opens the window.
---------------------------------------------------------------------------

local UI = Polestar.UI
local PACK_PAGE = "pack:every-quest"

-- On this pack's page in the guide menu: a button level with the title, at the header's right.
local packButton
local function showOnPackPage()
	local P = UI and UI.Picker
	local win = _G.PolestarPicker
	if not (P and win and win.Header and P.Category and P.Section) then return end
	local here = P.Section() == P.GUIDES and P.Category() == PACK_PAGE
	if here and not packButton then
		packButton = W.Button(win.Header, L["Options"], function() EQ.ShowOptions() end, { width = 90, height = 26 })
		packButton:SetPoint("TOPRIGHT", win.Header, "TOPRIGHT", -16, -32)
		packButton:SetFrameLevel(win.Header:GetFrameLevel() + 20)
	end
	if packButton then packButton:SetShown(here) end
end
if UI and UI.Picker and UI.Picker.Render then hooksecurefunc(UI.Picker, "Render", showOnPackPage) end

-- In the guide window, while the route is the open guide: a gear on the tab strip.
local gear
local function onTheRoute()
	local E = Polestar.Engine
	local g = E and E.GetGuide and E.GetGuide()
	return g ~= nil and g.id == EQ.ROUTE_ID
end
local function showGear()
	local frame = _G.PolestarGuideFrame
	if not frame then return end
	local here = onTheRoute() and not (Polestar.Get and Polestar.Get("ui.compact"))
	if here and not gear then
		gear = W.IconButton(frame, "gear", 22, L["Every Quest options"], function() EQ.ShowOptions() end)
		gear:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -7)
		gear:SetFrameLevel(frame:GetFrameLevel() + 20)
	end
	if gear then gear:SetShown(here) end
end
if Polestar.On then
	Polestar.On("GUIDE_CHANGED", showGear)
	Polestar.On("TABS_CHANGED", showGear)
	Polestar.On("SETTING_CHANGED", showGear)
end

-- The panel Polestar shows at the end of a guide, on the route: compute it, instead of "pick your next guide". The
-- route's guide ends at once while nothing is computed (its only step is a note) and for good when all is done.
local function routeOver(GF)
	local E = Polestar.Engine
	if not (onTheRoute() and E.GetStepIndex and E.GetStepView) then return false end
	local index = GF.catchUpIndex or E.GetStepIndex()
	return not (index and E.GetStepView(index))
end

local function takeOverEndPanel()
	local GF = UI and UI.GuideFrame
	local panel = GF and GF.parts and GF.parts.empty
	if not (panel and panel.Primary and panel.Secondary and panel.Title and panel.Text and panel.Glyph) then return end
	-- Polestar fills the panel, shows its button last, and only then lays the panel out: this is in time for that.
	hooksecurefunc(panel.Primary, "Show", function()
		if not routeOver(GF) then return end
		if EQ.DB().route then
			panel.Title:SetText(L["Route finished"])
			panel.Text:SetText(L["Compute a new one for what this character still has left. Options chooses which quests count."])
		else
			panel.Title:SetText(L["No route yet"])
			panel.Text:SetText(L["Compute the shortest route from where you stand, through the quests this character has left. Options chooses which quests count."])
		end
		W.SetButtonText(panel.Primary, L["Compute my route"])
		panel.Primary.psAction = function() EQ.Plan() end
		W.SetButtonText(panel.Secondary, L["Options"])
		panel.Secondary.psAction = function() EQ.ShowOptions() end
		panel.Secondary:Show()
	end)
	-- Polestar's check mark says something is done, and it paints that after the button. With no route, nothing is:
	-- the mark its own empty panels have, once it has laid this one out.
	if GF.Layout then
		hooksecurefunc(GF, "Layout", function()
			if panel:IsShown() and not EQ.DB().route and routeOver(GF) then
				panel.Glyph:SetTexture(Theme.Media("emblem"))
				W.Color(panel.Glyph, "accent")
				if panel.Glyph.Glow then W.Color(panel.Glyph.Glow, "accent", 0.16) end
			end
		end)
	end
end
if Polestar.OnInit then Polestar.OnInit(takeOverEndPanel) end

-- In the same window's menu, on the route: the options, and computing it again.
if W.ShowMenu then
	local showMenu = W.ShowMenu
	W.ShowMenu = function(anchor, items, opts)
		local guideMenu = false
		if type(items) == "table" and onTheRoute() then
			for _, item in ipairs(items) do
				if item.icon == "skip" then guideMenu = true end
			end
		end
		if guideMenu then
			table.insert(items, 1, { text = L["Every Quest options"], icon = "gear", onClick = function() EQ.ShowOptions() end })
			table.insert(items, 2, { text = L["Compute my route again"], icon = "reset", onClick = function() EQ.Plan() end })
			table.insert(items, 3, { text = L["Clear my route"], icon = "close", confirm = true, disabled = not EQ.DB().route,
				tip = L["Forgets this route and your marks on its steps. Your quests are not touched."],
				onClick = function() EQ.ClearRoute() end })
			table.insert(items, 4, { separator = true })
		end
		return showMenu(anchor, items, opts)
	end
end
