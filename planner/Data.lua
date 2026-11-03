-- Every Quest's data, for one faction. Each faction's catalog and metadata are files of their own, and a file of the
-- other faction stops at its first line, so a character holds its own side's data. With the faction not known yet (a
-- race that can be on either side) both load, and the first use keeps one.

PolestarEveryQuest = PolestarEveryQuest or {}
local EQ = PolestarEveryQuest

EQ.catalog = {}
local sides = {}

local function side(faction)
	sides[faction] = sides[faction] or { catalog = {} }
	return sides[faction]
end

function PolestarEveryQuestCatalog(def)
	local s = side(def.faction)
	s.catalog[#s.catalog + 1] = def
end

function PolestarEveryQuestMetaOf(faction, meta)
	side(faction).meta = meta
end

local RACE_SIDE = {
	Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
	Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
}

-- "Horde", "Alliance", or nil: the game's word, else the race's, which the game knows earlier at login.
function EQ.PlayerFaction()
	local C = Polestar.Compat
	local faction = C and C.GetPlayerFaction and C.GetPlayerFaction()
	if faction then return faction end
	if UnitRace then
		local _, race = UnitRace("player")
		return RACE_SIDE[race]
	end
	return nil
end

function PolestarEveryQuestWants(faction)
	local mine = EQ.PlayerFaction()
	return mine == nil or mine == faction
end

-- `faction`'s data from now on: EQ.catalog and PolestarEveryQuestMeta. -> whether it has any. keepBoth: for the tests, which
-- look at one side and then the other.
function EQ.UseFaction(faction, keepBoth)
	if faction ~= nil and EQ.faction == faction then return true end
	local s = faction and sides[faction]
	if not (s and s.meta and s.catalog[1]) then return false end
	EQ.faction, EQ.catalog, PolestarEveryQuestMeta = faction, s.catalog, s.meta
	EQ.stepsOf = nil
	if not keepBoth then sides = { [faction] = s } end
	return true
end
