#!/usr/bin/env node
'use strict';
// The whole addon against the real Polestar, in Polestar's simulated world: for a few characters and
// histories, compute a route, play it to the end with the real engine, then load the saved route again.
//
//   node tests/integration.js <polestar clone> [--ticks 3000]
const fs = require('node:fs');
const path = require('node:path');

const clone = path.resolve(process.argv[2] || '../polestar');
const opt = (name, dflt) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : dflt; };
const TICKS = Number(opt('ticks', 3000));
const QUICK = process.argv.includes('--quick');
const PACK = path.resolve(__dirname, '..');
const DIST = path.join(PACK, 'dist', 'PolestarPack_EveryQuest');
const lua = require(path.join(clone, 'tests/helpers/lua'));
// On a Lua error in the test's own script, say which line of it failed.
function runAddon(opts) {
  try {
    return lua.runAddon(opts);
  } catch (e) {
    const m = String(e.stderr || '').match(/polestar-test[^:]*\.lua:(\d+):/);
    if (m) console.log(`failed at: ${lua.buildProgram(opts).split('\n')[Number(m[1]) - 1]}`);
    throw e;
  }
}
// Polestar's simulated player stops after 4000 actions, which a whole Alliance route goes past.
const SIMULATE = require(path.join(clone, 'tools/lib/playtest')).SIMULATE.replace('guard < 4000', 'guard < 20000');

const frames = JSON.parse(fs.readFileSync(path.join(clone, 'data/forever/map-frames.json'), 'utf8'));
const zones = JSON.parse(fs.readFileSync(path.join(clone, 'data/forever/zones.json'), 'utf8'));
const all = { ...(frames.forever || {}), ...(frames.era || {}) };
const maps = Object.entries(all).map(([id, f]) => `w.addMap(${id}, { name = ${JSON.stringify(zones[id]?.name || '')}, c = ${f.c}, left = ${f.left}, right = ${f.right}, top = ${f.top}, bottom = ${f.bottom} })`).join('\n');

const histories = fs.existsSync(path.join(PACK, 'tests/histories.json')) ? JSON.parse(fs.readFileSync(path.join(PACK, 'tests/histories.json'), 'utf8')) : [];

const popups = `
    StaticPopupDialogs = {}
    SHOWN_POPUPS = {}
    function StaticPopup_Show(which, a, b) SHOWN_POPUPS[#SHOWN_POPUPS + 1] = { which = which, a = a, b = b } end`;

function before(persona, done) {
  return `
    local w = stub.world
    ${maps}
    w.race, w.raceName = ${JSON.stringify(persona.race)}, ${JSON.stringify(persona.race === 'Scourge' ? 'Undead' : persona.race)}
    w.class, w.className = ${JSON.stringify(persona.cls)}, ${JSON.stringify(persona.cls)}
    w.faction = ${JSON.stringify(persona.faction || 'Horde')}
    w.level = ${persona.level || 60}
    w.moveTo(${persona.at || '1411, 45.5, 12.5'})
    stub.addons[#stub.addons + 1] = { name = "PolestarPack_EveryQuest", title = "Polestar Community: Every Quest", loaded = true }
    stub.addonMeta.PolestarPack_EveryQuest = { ["X-Polestar-Pack"] = "every-quest", ["X-Polestar-Format"] = "3", ["X-Polestar-Needs"] = "0.2.5", Title = "Polestar Community: Every Quest" }
    for _, q in ipairs({ ${done.join(',')} }) do w.completed[q] = true end
    ${popups}
    ${persona.locale ? `function GetLocale() return ${JSON.stringify(persona.locale)} end` : ''}`;
}

function play(persona, done, label) {
  const run = runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, done),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      stub.fire("QUEST_LOG_UPDATE")
      Polestar.Set("behavior.autoNextGuide", false)
      Polestar.Set("behavior.groupQuests", "skip")
      local planned = PolestarEveryQuest.Plan({ sync = true, ticks = ${TICKS} })
      local g = Polestar.Guides.Get and Polestar.Guides.Get("every-quest/route")
      emit({ planned = planned, registered = g ~= nil, steps = g and #g.steps or 0, saved = PolestarEveryQuestDB and PolestarEveryQuestDB.route and #PolestarEveryQuestDB.route or 0, open = Polestar.Engine.GetGuide() and Polestar.Engine.GetGuide().id or "none", route = PolestarEveryQuestDB and PolestarEveryQuestDB.route })
      Polestar.Engine.SetGuide("every-quest/route")
      SIM_GUIDE = Polestar.Engine.GetGuide()
      stub.advance(0.6)
      ${SIMULATE}
    `,
  });
  return run;
}

function restore(persona, groups) {
  const saved = `PolestarEveryQuest.UseFaction(${JSON.stringify(persona.faction || 'Horde')}); PolestarEveryQuestDB = { groupLevel = 45, seconds = 30, build = PolestarEveryQuestMeta.build, route = { ${groups.map((g) => `{${g.join(',')}}`).join(',')} } }`;
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    saved: { PolestarPack_EveryQuest: saved },
    script: `
      stub.login()
      local g = Polestar.Guides.Get and Polestar.Guides.Get("every-quest/route")
      emit({ registered = g ~= nil, steps = g and #g.steps or 0 })
    `,
  });
}

// Nothing happens at login, no question and no computing. The player opens the guide, and its button computes the route
// under the progress bar.
function atLogin(persona, saved) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    saved: saved ? { PolestarPack_EveryQuest: saved } : undefined,
    script: `
      stub.login()
      debugprofilestop = function() return os.clock() * 1000 end
      Polestar.Set("behavior.autoNextGuide", false)
      local computingAtLogin = PolestarEveryQuest.IsComputing()
      stub.advance(6)
      local result = {
        computingAtLogin = computingAtLogin,
        computingAfterDelay = PolestarEveryQuest.IsComputing(),
        popups = #SHOWN_POPUPS,
        barAtLogin = _G.PolestarEveryQuestProgress ~= nil and _G.PolestarEveryQuestProgress:IsShown(),
        routeKept = PolestarEveryQuest.DB().route ~= nil,
      }
      ${saved ? '' : `
      Polestar.Engine.OpenTab("every-quest/route", true)
      local panel = Polestar.UI.GuideFrame.parts.empty
      _G.PolestarGuideFrame:Show()
      stub.advance(0.6)
      result.title = panel.Title:GetText()
      result.primary = panel.Primary:IsShown() and panel.Primary.Label:GetText()
      result.secondary = panel.Secondary:IsShown() and panel.Secondary.Label:GetText()
      PolestarEveryQuest.DB().seconds = 2
      panel.Primary:GetScript("OnClick")(panel.Primary)
      result.computingAfterPress = PolestarEveryQuest.IsComputing()
      local bar = _G.PolestarEveryQuestProgress
      result.barShown = bar and bar:IsShown() or false
      local frames = 0
      while PolestarEveryQuest.IsComputing() and frames < 200000 do stub.advance(0.02); frames = frames + 1 end
      result.barText = bar and bar.text and bar.text:GetText()
      result.barHiddenAfter = bar and not bar:IsShown()
      result.frames = frames
      result.routeAfter = #Polestar.Guides.Get("every-quest/route").steps > 1
      result.open = Polestar.Engine.GetGuide() and Polestar.Engine.GetGuide().id
      `}
      emit(result)
    `,
  });
}

// Cancel and finish now, from the bar's buttons.
function buttons(persona) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      debugprofilestop = function() return os.clock() * 1000 end
      PolestarEveryQuest.Plan({ seconds = 300 })
      stub.advance(0.02)
      local finish, cancel = _G.PolestarEveryQuestProgress.Finish, _G.PolestarEveryQuestProgress.Cancel
      local r = { hasButtons = finish ~= nil and cancel ~= nil }
      cancel:GetScript("OnClick")(cancel)
      r.cancelled = not PolestarEveryQuest.IsComputing() and not _G.PolestarEveryQuestProgress:IsShown() and #Polestar.Guides.Get("every-quest/route").steps == 1 and not (PolestarEveryQuestDB and PolestarEveryQuestDB.route)
      PolestarEveryQuest.Plan({ seconds = 300 })
      stub.advance(0.02)
      finish:GetScript("OnClick")(finish)
      local frames = 0
      while PolestarEveryQuest.IsComputing() and frames < 200000 do stub.advance(0.02); frames = frames + 1 end
      r.finishedEarly = not PolestarEveryQuest.IsComputing() and #Polestar.Guides.Get("every-quest/route").steps > 1
      r.frames = frames
      r.packStatus = Polestar.Guides.Pack and Polestar.Guides.Pack("every-quest") and Polestar.Guides.Pack("every-quest").status
      local first = Polestar.Guides.Get("every-quest/route")
      local firstTitle = first.steps[1].goals[1].title
      r.replanned = PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      local second = Polestar.Guides.Get("every-quest/route")
      r.replaced = second ~= first and #second.steps > 1 and second.steps[1].goals[1].title ~= nil and Polestar.Engine.GetGuide().id == "every-quest/route"
      emit(r)
    `,
  });
}

// A place in the Alliance's world for its characters: the integration world only needs one on the map.
const ALLIANCE = { faction: 'Alliance', at: '1429, 50, 50' };
const personas = [
  { race: 'Orc', cls: 'WARRIOR' },
  { race: 'Scourge', cls: 'MAGE' },
  { race: 'Tauren', cls: 'DRUID' },
  { race: 'Human', cls: 'WARRIOR', ...ALLIANCE },
  { race: 'NightElf', cls: 'DRUID', ...ALLIANCE },
  { race: 'Dwarf', cls: 'PALADIN', ...ALLIANCE },
  { race: 'Gnome', cls: 'MAGE', ...ALLIANCE },
];
const cases = [];
cases.push([{ race: 'Scourge', cls: 'WARRIOR', level: 3 }, [], 'level 3, nothing done']);
for (const p of personas) cases.push([p, [], 'nothing done']);
for (const h of histories.slice(1, 4)) cases.push([personas[0], h.done, h.label]);

// The route computed over frames, as in game, on a real clock.
function overFrames(persona) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      debugprofilestop = function() return os.clock() * 1000 end
      local started = os.clock()
      PolestarEveryQuest.Plan({ seconds = 2 })
      local frames = 0
      while PolestarEveryQuest.IsComputing() and frames < 200000 do
        stub.advance(0.02)
        frames = frames + 1
      end
      local g = Polestar.Guides.Get("every-quest/route")
      emit({ registered = g ~= nil, steps = g and #g.steps or 0, frames = frames, seconds = os.clock() - started })
    `,
  });
}

// The window: the switches change what the route holds, and a route with a reputation to grind plays to its end.
function windowTest(persona) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      Polestar.Set("behavior.autoNextGuide", false)
      Polestar.Set("behavior.groupQuests", "skip")
      local r = {}
      local F = PolestarEveryQuest.ShowOptions()
      r.shown = F:IsShown()
      r.base = F.Total:GetText()
      local function find(name)
        for _, row in ipairs(F.Rows) do
          if row.psName == name then return row end
        end
      end
      local raid = find("Raid quests")
      r.raidLabel = raid.Label:GetText()
      r.raidOff = PolestarEveryQuestDB.raid
      raid:GetScript("OnClick")(raid, "LeftButton")
      r.withRaid = F.Total:GetText()
      r.raidSaved = PolestarEveryQuestDB.raid
      raid:GetScript("OnClick")(raid, "LeftButton")
      r.raidBack = F.Total:GetText()
      r.pvpLabel = find("PvP quests").Label:GetText()
      find("PvP quests"):GetScript("OnClick")(find("PvP quests"), "LeftButton")
      r.withPvp = F.Total:GetText()
      r.pvpSaved = PolestarEveryQuestDB.pvp
      local hallow = find("Hallow's End")
      r.hallowLabel = hallow.Label:GetText()
      hallow:GetScript("OnClick")(hallow, "LeftButton")
      r.withHallow = F.Total:GetText()
      local grind = find("Reputation quests, grinding what they need")
      r.grindLabel = grind.Label:GetText()
      grind:GetScript("OnClick")(grind, "LeftButton")
      r.withGrind = F.Total:GetText()
      F.Compute:GetScript("OnClick")(F.Compute)
      r.closedOnCompute = not F:IsShown()
      r.computing = PolestarEveryQuest.IsComputing()
      -- Back to a fixed amount of work, with the same choices.
      debugprofilestop = function() return os.clock() * 1000 end
      local frames = 0
      while PolestarEveryQuest.IsComputing() and frames < 400000 do stub.advance(0.02); frames = frames + 1 end
      local g = Polestar.Guides.Get("every-quest/route")
      r.steps = #g.steps
      local reps, firstRep, firstQuest = 0, nil, nil
      for i, s in ipairs(g.steps) do
        for _, goal in ipairs(s.goals) do
          if goal.t == "rep" then reps = reps + 1; firstRep = firstRep or (s.title .. " at step " .. i) end
        end
      end
      r.reps, r.firstRep = reps, firstRep
      r.savedStrings = 0
      for _, refs in ipairs(PolestarEveryQuestDB.route) do
        for _, ref in ipairs(refs) do if type(ref) == "string" then r.savedStrings = r.savedStrings + 1 end end
      end
      local again = PolestarEveryQuest.StepsFromGroups(PolestarEveryQuestDB.route)
      r.reloadedSteps = #again
      emit(r)
      Polestar.Engine.SetGuide("every-quest/route")
      SIM_GUIDE = Polestar.Engine.GetGuide()
      stub.advance(0.6)
      ${SIMULATE}
    `,
  });
}

// The ways to the window from Polestar's own windows, without a change to Polestar.
function linksTest(persona) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      Polestar.Set("behavior.autoNextGuide", false)
      local r = {}
      local UI, W = Polestar.UI, Polestar.Widgets
      -- The pack's page in the guide menu.
      UI.ShowPicker()
      local P, win = UI.Picker, _G.PolestarPicker
      P.SetCategory("pack:every-quest")
      P.Render()
      local button
      for _, c in ipairs({ win.Header:GetChildren() }) do
        if type(c.Label) == "table" and c.Label.GetText and c.Label:GetText() == "Options" then button = c end
      end
      r.buttonOnPackPage = button ~= nil and button:IsShown()
      if button then
        button:GetScript("OnClick")(button)
        r.opensWindow = _G.PolestarEveryQuestOptions ~= nil and _G.PolestarEveryQuestOptions:IsShown()
        _G.PolestarEveryQuestOptions:Hide()
      end
      P.SetCategory("All")
      P.Render()
      r.hiddenElsewhere = button ~= nil and not button:IsShown()
      win:Hide()
      -- The guide window, on the route.
      PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      Polestar.Engine.SetGuide("every-quest/route")
      stub.advance(0.6)
      local F = _G.PolestarGuideFrame
      local gear
      for _, c in ipairs({ F:GetChildren() }) do
        if c.psTip == "Every Quest options" then gear = c end
      end
      r.gearFound = gear ~= nil
      r.gearShown = gear ~= nil and gear:IsShown()
      if gear then
        gear:GetScript("OnClick")(gear)
        r.gearOpensWindow = _G.PolestarEveryQuestOptions:IsShown()
        _G.PolestarEveryQuestOptions:Hide()
      end
      -- Its menu.
      local seen
      local inner = W.ShowMenu
      W.ShowMenu = function(a, items, o) seen = items; return inner(a, items, o) end
      local GF = UI.GuideFrame or (UI.GF)
      local menu = GF and GF.menuButton
      r.menuFound = menu ~= nil
      if menu then
        menu:GetScript("OnClick")(menu)
        r.menuFirst = seen and seen[1] and seen[1].text
        r.menuSecond = seen and seen[2] and seen[2].text
        if W.HideMenu then W.HideMenu() end
      end
      -- Another guide: the gear goes, the menu is Polestar's own.
      local other = "every-quest/another"
      Polestar.RegisterGuide({ id = other, pack = "every-quest", title = "Another", steps = { { title = "Another", goals = { { t = "goto", map = 1411, x = 50, y = 50 } } } } })
      r.other = other
      if other then
        Polestar.Engine.SetGuide(other)
        stub.advance(0.6)
        r.gearHiddenElsewhere = gear ~= nil and not gear:IsShown()
        if menu then
          seen = nil
          menu:GetScript("OnClick")(menu)
          r.menuElsewhere = seen and seen[1] and seen[1].text
          if W.HideMenu then W.HideMenu() end
        end
      end
      emit(r)
    `,
  });
}

// The guide window at the end of the route, with no route yet and with one finished: compute, in place of "pick your
// next guide". Every other guide keeps Polestar's own panel.
function endPanelTest(persona) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      debugprofilestop = function() return os.clock() * 1000 end
      Polestar.Set("behavior.autoNextGuide", false)
      local r = {}
      local w = stub.world
      local UI, E = Polestar.UI, Polestar.Engine
      local panel = UI.GuideFrame.parts.empty
      local F = _G.PolestarGuideFrame
      F:Show()
      local function look()
        stub.advance(0.6)
        return {
          shown = panel:IsShown(),
          title = panel.Title:GetText(),
          primary = panel.Primary:IsShown() and panel.Primary.Label:GetText() or nil,
          secondary = panel.Secondary:IsShown() and panel.Secondary.Label:GetText() or nil,
          glyph = panel.Glyph:GetTexture(),
        }
      end
      local function press(b) b:GetScript("OnClick")(b) end
      local function computed()
        local frames = 0
        while PolestarEveryQuest.IsComputing() and frames < 200000 do stub.advance(0.02); frames = frames + 1 end
        return #Polestar.Guides.Get("every-quest/route").steps
      end
      PolestarEveryQuest.DB().seconds = 1

      -- No route yet: the guide holds only its note.
      E.SetGuide("every-quest/route")
      r.noRoute = look()
      r.noRouteEmblem = r.noRoute.glyph == Polestar.Theme.Media("emblem")

      -- Another guide that ends at once keeps Polestar's panel, whatever came before it.
      Polestar.RegisterGuide({ id = "every-quest/another", pack = "every-quest", title = "Another", steps = { { title = "Another", goals = { { t = "note", text = "Done." } } } } })
      E.SetGuide("every-quest/another")
      r.other = look()
      r.otherCheck = r.other.glyph == Polestar.Theme.Media("check")
      E.SetGuide("every-quest/route")
      look()

      -- Its button computes the route, and the steps replace the panel.
      press(panel.Primary)
      r.computing = PolestarEveryQuest.IsComputing()
      r.steps = computed()
      r.after = look()
      r.onRoute = E.GetGuide().id == "every-quest/route"
      r.stepShown = E.GetStepView(E.GetStepIndex()) ~= nil

      -- All of it done, PvP apart (it was not asked for): the route is over, with the same buttons.
      for q, m in pairs(PolestarEveryQuestMeta.quests) do
        if m.kind ~= "pvp" then w.completed[q] = true end
      end
      stub.fire("QUEST_LOG_UPDATE")
      r.finished = look()
      r.finishedCheck = r.finished.glyph == Polestar.Theme.Media("check")

      -- Options opens the window.
      press(panel.Secondary)
      r.optionsOpen = _G.PolestarEveryQuestOptions:IsShown()
      _G.PolestarEveryQuestOptions:Hide()

      -- Nothing left: said, not computed, and the panel stays.
      press(panel.Primary)
      r.nothingLeftComputes = PolestarEveryQuest.IsComputing()
      r.stillFinished = look()

      -- PvP asked for in the window: a new route from the same button, and the panel gives way to its steps.
      PolestarEveryQuest.DB().pvp = true
      local stale = look()
      r.waitsForTheButton = stale.shown and stale.title == "Route finished"
      press(panel.Primary)
      r.computingAgain = PolestarEveryQuest.IsComputing()
      r.againSteps = computed()
      r.againShown = look().shown
      r.againStep = E.GetStepView(E.GetStepIndex()) ~= nil
      emit(r)
    `,
  });
}

// Clearing the route: from the window and the menu, a second click acting; the tab stays and says there is no route;
// Polestar's marks on the old steps go, in a clear and in a new route alike.
function clearTest(persona) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before(persona, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      debugprofilestop = function() return os.clock() * 1000 end
      Polestar.Set("behavior.autoNextGuide", false)
      local r = {}
      local ID = "every-quest/route"
      local UI, W, E = Polestar.UI, Polestar.Widgets, Polestar.Engine
      local panel = UI.GuideFrame.parts.empty
      _G.PolestarGuideFrame:Show()
      local function press(b) b:GetScript("OnClick")(b) end
      local function stepsOf() return #Polestar.Guides.Get(ID).steps end
      local function marks()
        local s = Polestar.CharState()
        return {
          skipped = s.skipped[ID] ~= nil, manual = s.manual[ID] ~= nil, when = s.when[ID] ~= nil,
          pin = type(s.pins) == "table" and s.pins[ID] ~= nil,
        }
      end
      local function tabIds()
        local out = {}
        for i, t in ipairs(E.GetTabs()) do out[i] = t.guideId end
        return table.concat(out, ",")
      end

      -- No route: nothing to clear, and the window's button says so.
      r.noRouteClears = PolestarEveryQuest.ClearRoute()
      PolestarEveryQuest.ShowOptions()
      local win = _G.PolestarEveryQuestOptions
      r.buttonOffWithoutRoute = not win.Clear:IsEnabled()
      win:Hide()

      -- A route, on the active tab, with a step skipped.
      PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      stub.advance(0.6)
      r.steps = stepsOf()
      E.Skip()
      stub.advance(0.6)
      r.marksBefore = marks()
      r.waypointBefore = E.GetWaypoint() ~= nil

      -- The menu holds it, in second click style.
      local seen
      local inner = W.ShowMenu
      W.ShowMenu = function(a, items, o) seen = items; return inner(a, items, o) end
      local menu = UI.GuideFrame.menuButton
      menu:GetScript("OnClick")(menu)
      local item = seen and seen[3]
      r.menuThird = item and item.text
      r.menuConfirms = item and item.confirm
      r.menuEnabled = item and not item.disabled
      if W.HideMenu then W.HideMenu() end
      r.menuAfterIsSeparator = seen and seen[4] and seen[4].separator

      -- The window: on with a route, a first click only arms it, the second clears.
      PolestarEveryQuest.ShowOptions()
      r.buttonOnWithRoute = win.Clear:IsEnabled()
      local label = win.Clear.Label:GetText()
      press(win.Clear)
      r.armedSays = win.Clear.Label:GetText() ~= label
      r.firstClickKeeps = PolestarEveryQuestDB.route ~= nil and stepsOf() == r.steps
      press(win.Clear)
      stub.advance(0.6)
      r.cleared = PolestarEveryQuestDB.route == nil and PolestarEveryQuestDB.routeSteps == nil and PolestarEveryQuestDB.build == nil
      r.stepsAfter = stepsOf()
      r.labelBack = win.Clear.Label:GetText() == label
      r.buttonOffAfter = not win.Clear:IsEnabled()
      win:Hide()
      r.stillOnRoute = E.GetGuide() and E.GetGuide().id == ID
      r.panelShown = panel:IsShown()
      r.panelTitle = panel.Title:GetText()
      r.primary = panel.Primary.Label:GetText()
      r.marksAfter = marks()
      r.waypointAfter = E.GetWaypoint() ~= nil

      -- The menu's line is off with no route.
      seen = nil
      menu:GetScript("OnClick")(menu)
      r.menuOffAfter = seen and seen[3] and seen[3].disabled
      if W.HideMenu then W.HideMenu() end

      -- Computed again: the skip of the old route's step does not fall on the new one.
      PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      stub.advance(0.6)
      r.newRouteSteps = stepsOf()
      r.newFirstSkipped = E.GetStepView(1) and E.GetStepView(1).skipped and true or false
      r.newOnFirstStep = E.GetStepIndex()

      -- Computing over a route forgets its marks as well.
      E.Skip()
      stub.advance(0.6)
      r.marksOverBefore = marks()
      PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      stub.advance(0.6)
      r.marksOverAfter = marks()
      r.overFirstSkipped = E.GetStepView(1) and E.GetStepView(1).skipped and true or false

      -- The route's tab in the background: the player stays on the guide they are on, the tabs keep their order.
      Polestar.RegisterGuide({ id = "every-quest/another", pack = "every-quest", title = "Another", steps = { { title = "Another", goals = { { t = "goto", map = 1411, x = 50, y = 50 } } } } })
      E.OpenTab("every-quest/another", true)
      stub.advance(0.6)
      E.MoveTab(#E.GetTabs(), 1)
      stub.advance(0.6)
      r.tabsBefore = tabIds()
      r.backgroundClears = PolestarEveryQuest.ClearRoute()
      stub.advance(0.6)
      r.tabsAfter = tabIds()
      r.activeStays = E.GetGuide() and E.GetGuide().id
      E.SetGuide(ID)
      stub.advance(0.6)
      r.backgroundPanel = panel:IsShown() and panel.Title:GetText() or nil

      -- While a route is on its way: it stops, and no route comes later. With an old route the old one goes too.
      PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      PolestarEveryQuest.Plan({ seconds = 300 })
      stub.advance(0.02)
      r.computing = PolestarEveryQuest.IsComputing()
      r.computingClears = PolestarEveryQuest.ClearRoute()
      r.stopped = not PolestarEveryQuest.IsComputing() and not _G.PolestarEveryQuestProgress:IsShown()
      stub.advance(1)
      r.nothingLater = PolestarEveryQuestDB.route == nil and stepsOf() == 1

      -- Through the command as well, on a route with no tab: its guide is empty, and no tab appears.
      PolestarEveryQuest.Plan({ sync = true, ticks = 100 })
      for i, t in ipairs(E.GetTabs()) do
        if t.guideId == ID then E.CloseTab(i); break end
      end
      stub.advance(0.6)
      local tabsNoRoute = tabIds()
      PolestarEveryQuest.Command("clear")
      stub.advance(0.6)
      r.commandClears = PolestarEveryQuestDB.route == nil and stepsOf() == 1
      r.noTabOpened = tabIds() == tabsNoRoute
      emit(r)
    `,
  });
}

// An Alliance character: its own side's data and quests, and a route that plays to its end.
function allianceTest() {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before({ race: 'Human', cls: 'WARRIOR', ...ALLIANCE }, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      stub.advance(6)
      Polestar.Set("behavior.autoNextGuide", false)
      Polestar.Set("behavior.groupQuests", "skip")
      local r = { popups = #SHOWN_POPUPS, forThis = PolestarEveryQuest.ForThisCharacter(), faction = PolestarEveryQuest.faction }
      r.ownQuest = PolestarEveryQuestMeta.quests[783] ~= nil
      r.hordeQuest = PolestarEveryQuestMeta.quests[787] ~= nil
      r.ownCatalog = PolestarEveryQuest.catalog[1].faction
      local F = PolestarEveryQuest.ShowOptions()
      r.total = F.Total:GetText()
      r.computeEnabled = F.Compute:IsEnabled()
      F:Hide()
      r.planned = PolestarEveryQuest.Plan({ sync = true, ticks = ${Math.min(TICKS, 200)} })
      local g = Polestar.Guides.Get("every-quest/route")
      r.steps = #g.steps
      r.guideFaction = g.faction
      r.savedFaction = PolestarEveryQuestDB.faction
      emit(r)
      Polestar.Engine.SetGuide("every-quest/route")
      SIM_GUIDE = Polestar.Engine.GetGuide()
      stub.advance(0.6)
      ${SIMULATE}
    `,
  });
}

// The interface in a language: every text that formats something, and nothing left in English where it is translated.
function localeTest(locale) {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before({ race: 'Orc', cls: 'WARRIOR', locale }, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      debugprofilestop = function() return os.clock() * 1000 end
      Polestar.Set("behavior.autoNextGuide", false)
      local EQ, L = PolestarEveryQuest, PolestarEveryQuest.L
      local r = {}
      local said = {}
      local printing = Polestar.Print
      Polestar.Print = function(text) said[#said + 1] = text; return printing(text) end
      local panel = Polestar.UI.GuideFrame.parts.empty
      _G.PolestarGuideFrame:Show()
      r.guideTitle = Polestar.Guides.Get("every-quest/route").title
      Polestar.Engine.OpenTab("every-quest/route", true)
      stub.advance(0.6)
      r.panelTitle = panel.Title:GetText()
      r.panelButton = panel.Primary.Label:GetText()
      -- The window, with everything that makes a number or a name appear.
      EQ.DB().grindRep = true
      local F = EQ.ShowOptions()
      r.total = F.Total:GetText()
      r.compute = F.Compute.Label:GetText()
      F:Hide()
      -- Every command, and the route with a reputation to grind.
      EQ.Command("status")
      EQ.Command("group")
      EQ.Command("group 40")
      EQ.Command("seconds")
      EQ.Command("seconds 2")
      EQ.Command("open")
      EQ.Command("clear")
      EQ.Command("nonsense")
      EQ.Plan({ sync = true, ticks = 50 })
      local rep, repNote
      for _, s in ipairs(Polestar.Guides.Get("every-quest/route").steps) do
        for _, g in ipairs(s.goals) do
          if g.t == "rep" and not rep then rep, repNote = s.title, g.note end
        end
      end
      r.repStep, r.repNote = rep, repNote
      EQ.Plan({ seconds = 1 })
      stub.advance(0.02)
      r.bar = _G.PolestarEveryQuestProgress.text:GetText()
      local frames = 0
      while EQ.IsComputing() and frames < 200000 do stub.advance(0.02); frames = frames + 1 end
      EQ.ClearRoute()
      Polestar.Print = printing
      r.said = #said
      r.english = 0
      for _, text in ipairs(said) do
        if text:find("your route", 1, true) or text:find("quests to do", 1, true) then r.english = r.english + 1; r.sample = text end
      end
      r.eventName = EQ.EVENTS[6].name
      emit(r)
    `,
  });
}

// A character with no faction yet: told, and nothing computed, until it has one. Then it finds its side's data.
function noFactionTest() {
  return runAddon({
    stubs: ['stub_world.lua'],
    before: before({ race: 'Skyborne', cls: 'WARRIOR', faction: 'Neutral' }, []),
    addons: ['Polestar', { name: 'PolestarPack_EveryQuest', dir: DIST }],
    script: `
      stub.login()
      stub.advance(6)
      local r = { popups = #SHOWN_POPUPS, planned = PolestarEveryQuest.Plan({ sync = true, ticks = 10 }), steps = #Polestar.Guides.Get("every-quest/route").steps }
      local F = PolestarEveryQuest.ShowOptions()
      r.total = F.Total:GetText()
      r.computeEnabled = F.Compute:IsEnabled()
      F:Hide()
      stub.world.faction = "Horde"
      r.forThisAfter = PolestarEveryQuest.ForThisCharacter()
      r.factionAfter = PolestarEveryQuest.faction
      F = PolestarEveryQuest.ShowOptions()
      r.computeEnabledAfter = F.Compute:IsEnabled()
      emit(r)
    `,
  });
}

const LOCALES = ['deDE', 'esES', 'esMX', 'frFR', 'koKR', 'ptBR', 'ruRU', 'zhCN', 'zhTW'];
let failed = 0;
const undead = { race: 'Scourge', cls: 'WARRIOR' };
{
  const r = atLogin(undead).emitted[0];
  const ok = r && !r.computingAtLogin && !r.computingAfterDelay && r.popups === 0 && !r.barAtLogin && !r.routeKept
    && r.title === 'No route yet' && r.primary === 'Compute my route' && r.secondary === 'Options'
    && r.computingAfterPress && r.barShown && r.barHiddenAfter && r.routeAfter && r.open === 'every-quest/route';
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} nothing happens at login, the guide's button computes the route under its bar: ${JSON.stringify(r)}`);
  const stale = atLogin(undead, 'PolestarEveryQuestDB = { build = "another", route = { { 65537 } } }').emitted[0];
  const dropped = stale && stale.popups === 0 && !stale.routeKept;
  if (!dropped) failed++;
  console.log(`${dropped ? 'ok  ' : 'FAIL'} a route from another build is dropped, quietly: ${JSON.stringify(stale)}`);
  const saved = atLogin(undead, 'PolestarEveryQuest.UseFaction("Horde"); PolestarEveryQuestDB = { build = PolestarEveryQuestMeta.build, route = { { 65537 } } }').emitted[0];
  const kept = saved && saved.popups === 0 && saved.routeKept && !saved.computingAfterDelay;
  if (!kept) failed++;
  console.log(`${kept ? 'ok  ' : 'FAIL'} a saved route stays, and nothing is computed: ${JSON.stringify(saved)}`);
  const b = buttons(undead).emitted[0];
  const okB = b && b.hasButtons && b.cancelled && b.finishedEarly && b.frames < 2000 && b.replanned && b.replaced;
  if (!okB) failed++;
  console.log(`${okB ? 'ok  ' : 'FAIL'} the bar's buttons, cancel and finish now: ${JSON.stringify(b)}`);
}
{
  const run = linksTest(undead);
  const r = run.emitted[0];
  const ok = r && r.buttonOnPackPage && r.opensWindow && r.hiddenElsewhere && r.gearShown && r.gearOpensWindow && r.menuFirst === 'Every Quest options' && r.menuSecond === 'Compute my route again' && (!r.other || (r.gearHiddenElsewhere && r.menuElsewhere !== 'Every Quest options'));
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} the window opens from the pack's page, the guide window's gear and its menu: ${JSON.stringify(r)}${r ? '' : String(run.stderr || run.stdout || '').slice(0, 1500)}`);
  const a = allianceTest();
  const [al, alSim] = a.emitted;
  const okA = al && al.popups === 0 && al.forThis && al.faction === 'Alliance' && al.ownQuest && !al.hordeQuest && al.ownCatalog === 'Alliance'
    && al.computeEnabled && al.planned && al.steps > 100 && al.guideFaction === undefined && al.savedFaction === 'Alliance' && alSim && alSim.done && !alSim.stuck;
  if (!okA) failed++;
  console.log(`${okA ? 'ok  ' : 'FAIL'} an Alliance character has its side's quests and a route that plays to its end: ${JSON.stringify(al)}; play ${JSON.stringify(alSim && { done: alSim.done, stuck: alSim.stuck, steps: alSim.steps })}${al ? '' : String(a.stderr || a.stdout || '').slice(0, 1500)}`);
  const n = noFactionTest();
  const o = n.emitted[0];
  const okO = o && o.popups === 0 && o.planned === false && o.steps === 1 && o.computeEnabled === false && o.forThisAfter && o.factionAfter === 'Horde' && o.computeEnabledAfter;
  if (!okO) failed++;
  console.log(`${okO ? 'ok  ' : 'FAIL'} a character with no faction is told and nothing is computed, until it has one: ${JSON.stringify(o)}${o ? '' : String(n.stderr || n.stdout || '').slice(0, 1500)}`);
}
{
  const run = endPanelTest(undead);
  const r = run.emitted[0];
  const buttonsOk = (p) => p && p.shown && p.primary === 'Compute my route' && p.secondary === 'Options';
  const ok = r && buttonsOk(r.noRoute) && r.noRoute.title === 'No route yet' && r.noRouteEmblem
    && r.other && r.other.shown && r.other.title === 'Guide complete' && r.other.primary === 'Choose a guide' && !r.other.secondary && r.otherCheck
    && r.computing && r.steps > 1 && r.after && !r.after.shown && r.onRoute && r.stepShown
    && buttonsOk(r.finished) && r.finished.title === 'Route finished' && r.finishedCheck
    && r.optionsOpen && !r.nothingLeftComputes && buttonsOk(r.stillFinished)
    && r.waitsForTheButton && r.computingAgain && r.againSteps > 1 && r.againShown === false && r.againStep;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} the end of the route offers to compute it, other guides keep their panel: ${JSON.stringify(r)}${r ? '' : String(run.stderr || run.stdout || '').slice(0, 1500)}`);
}
{
  const run = clearTest(undead);
  const r = run.emitted[0];
  const none = (m) => m && !m.skipped && !m.manual && !m.when && !m.pin;
  const ok = r && r.noRouteClears === false && r.buttonOffWithoutRoute && r.steps > 1
    && r.marksBefore && r.marksBefore.skipped && r.waypointBefore
    && r.menuThird === 'Clear my route' && r.menuConfirms && r.menuEnabled && r.menuAfterIsSeparator
    && r.buttonOnWithRoute && r.armedSays && r.firstClickKeeps
    && r.cleared && r.stepsAfter === 1 && r.labelBack && r.buttonOffAfter
    && r.stillOnRoute && r.panelShown && r.panelTitle === 'No route yet' && r.primary === 'Compute my route'
    && none(r.marksAfter) && !r.waypointAfter && r.menuOffAfter
    && r.newRouteSteps > 1 && !r.newFirstSkipped && r.newOnFirstStep === 1
    && r.marksOverBefore && r.marksOverBefore.skipped && !r.marksOverAfter.skipped && !r.marksOverAfter.manual && !r.overFirstSkipped
    && r.backgroundClears && r.tabsBefore === r.tabsAfter && r.activeStays === 'every-quest/another' && r.backgroundPanel === 'No route yet'
    && r.computing && r.computingClears && r.stopped && r.nothingLater
    && r.commandClears && r.noTabOpened;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} the route can be cleared, and no marks stay behind: ${JSON.stringify(r)}${r ? '' : String(run.stderr || run.stdout || '').slice(0, 1500)}`);
}
for (const locale of LOCALES) {
  const run = localeTest(locale);
  const r = run.emitted[0];
  const ok = r && r.guideTitle !== 'Every Quest: your route' && r.panelTitle !== 'No route yet' && r.panelButton !== 'Compute my route'
    && r.compute !== 'Compute my route' && !/quests/.test(r.total) && r.repStep && !/^Reach /.test(r.repStep) && !/the route waits/.test(r.repNote || '')
    && r.bar && !/left, play on/.test(r.bar) && r.said >= 8 && r.english === 0 && r.eventName !== "Hallow's End";
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} the interface in ${locale}: ${JSON.stringify(r)}${r ? '' : String(run.stderr || run.stdout || '').slice(0, 1500)}`);
}
{
  const run = windowTest(undead);
  const [r, sim] = run.emitted;
  const n = (s) => Number(String(s).match(/\d+/)[0]);
  const ok = r && r.shown && /\(\d+\)/.test(r.raidLabel || '') && n(r.withRaid) > n(r.base) && r.raidSaved === true && r.raidBack === r.base && n(r.withPvp) > n(r.base) && n(r.withHallow) > n(r.withPvp) && r.pvpSaved === true && r.closedOnCompute && r.steps > 100 && r.reps > 0 && r.savedStrings === r.reps && r.reloadedSteps === r.steps && sim && sim.done && !sim.stuck;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} the window chooses the quests, the reputations are ground then their quests done: ${JSON.stringify(r)}; play ${JSON.stringify(sim && { done: sim.done, stuck: sim.stuck, visited: sim.visited, steps: sim.steps })}${r ? '' : String(run.stderr || run.stdout || '').slice(0, 1500)}`);
}
{
  const run = overFrames(personas[0]);
  const r = run.emitted[0];
  const ok = r && r.registered && r.steps > 1 && r.frames > 10 && r.seconds < 6;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} computed over frames: ${JSON.stringify(r)}${r ? '' : String(run.stderr || '').slice(0, 800)}`);
}
for (const [persona, done, label] of QUICK ? cases.slice(0, 1) : cases) {
  const t0 = Date.now();
  const run = play(persona, done, label);
  const [plan, sim] = run.emitted;
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  if (!plan) {
    failed++;
    console.log(`FAIL ${persona.race} ${persona.cls}, ${label}: nothing emitted\n${String(run.stderr || run.stdout || '').slice(0, 1200)}`);
    continue;
  }
  const { route, ...shown } = plan;
  const bad = !plan.registered || plan.steps < 2 || !sim || sim.stuck || !sim.done;
  if (bad) failed++;
  console.log(`${bad ? 'FAIL' : 'ok  '} ${persona.race} ${persona.cls}, ${label} (${done.length} done, ${secs} s): ${JSON.stringify(shown)}; play ${JSON.stringify(sim && { done: sim.done, stuck: sim.stuck, visited: sim.visited, steps: sim.steps, missing: (sim.missing || []).length, wrongPick: sim.wrongPick && sim.wrongPick.length })}`);
  if (sim && sim.stuck) console.log(`     stuck: ${JSON.stringify(sim.stuck).slice(0, 400)}`);
  if (route && persona.race === 'Orc' && !done.length) {
    const again = restore(persona, route).emitted[0];
    const ok = again && again.registered && again.steps === plan.steps;
    if (!ok) failed++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} saved route loads again: ${JSON.stringify(again)} (saved ${plan.saved} groups)`);
  }
}
console.log(failed ? `integration: ${failed} failed` : 'integration: all passed');
process.exit(failed ? 1 : 0);
