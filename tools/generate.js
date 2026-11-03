#!/usr/bin/env node
'use strict';
// The catalog: every quest of the list as .guide lines, written from Polestar's reference data.
// One quest after the other, so the guides lint and play to the end: the order players follow is
// computed in game (planner/). Also writes scope/excluded.json and scope/summary.md: what is left
// out and why, the list the addon publishes.
//
//   node tools/generate.js <polestar clone> [--faction Horde|Alliance] [--only-zone <uiMapID>,...] [--per-guide 250]
// Without --faction, both.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const args = process.argv.slice(2);
if (!args.includes('--faction')) {
  for (const faction of ['Horde', 'Alliance']) execFileSync(process.execPath, [__filename, ...args, '--faction', faction], { stdio: 'inherit' });
  process.exit(0);
}
const clone = path.resolve(args[0] || '../polestar');
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : dflt;
};
const FACTION = opt('faction', 'Horde');
const PER_GUIDE = Number(opt('per-guide', 250));
const ONLY_ZONES = opt('only-zone', null) ? new Set(opt('only-zone').split(',').map(Number)) : null;
const PACK = path.resolve(__dirname, '..');
const PACK_ID = 'every-quest';

const read = (f) => JSON.parse(fs.readFileSync(path.join(clone, 'data/forever', `${f}.json`), 'utf8'));
const quests = read('quests');
const npcs = read('npcs');
const objects = read('objects');
const items = read('items');
const frames = read('map-frames');
const zones = read('zones');

// The kind of each quest, from the client's QuestInfo as forever-db publishes it.
const questType = {};
const questArea = {};
for (const line of fs.readFileSync(path.join(clone, 'forever-db/data/quest.jsonl'), 'utf8').split('\n')) {
  if (!line) continue;
  const q = JSON.parse(line);
  if (q.type !== undefined) questType[q.id] = q.type;
  if (q.zone_area !== undefined) questArea[q.id] = q.zone_area;
}
const KIND = { 1: 'group', 41: 'pvp', 62: 'raid', 81: 'dungeon' };

// The dungeon journal (forge data codex): each instance's kind, entrance and quests, and the NPCs inside.
const codexDir = path.join(clone, 'data/forever/codex');
const journal = Object.values(JSON.parse(fs.readFileSync(path.join(codexDir, 'journal.json'), 'utf8')).dungeons);
const codexNpcs = JSON.parse(fs.readFileSync(path.join(codexDir, 'npcs.json'), 'utf8'));
const instanceOfQuest = new Map();
for (const d of journal) for (const q of d.quests || []) if (!instanceOfQuest.has(q.id)) instanceOfQuest.set(q.id, d);
const instanceByKey = new Map(journal.map((d) => [d.key, d]));
const questKind = (q) => {
  const inst = instanceOfQuest.get(q.id);
  if ((inst && inst.kind === 'raid') || needsWorldBoss(q)) return 'raid';
  if (q.maxLevel || inBattleground(q) || repsOf(q).some((r) => BATTLEGROUND_FACTIONS.has(r.faction)) || listedOut.get(q.id) === 'pvp') return 'pvp';
  const k = KIND[questType[q.id]];
  if (k) return k;
  return inst ? 'dungeon' : 'plain';
};
// A place from an instance's entrance, as guide modifiers.
const atEntrance = (inst) => {
  const e = inst && inst.entrance;
  if (!e || e.x == null || e.y == null || !e.map) return null;
  return `@${e.x},${e.y} map ${e.map} ${e.f === 'e' ? 'era' : 'live'}`;
};

const tightQuests = new Set();
for (const line of fs.readFileSync(path.join(clone, 'forever-db/data/mechanic.jsonl'), 'utf8').split('\n')) {
  if (!line) continue;
  const m = JSON.parse(line);
  if (m.kind === 'timed' || m.kind === 'escort') tightQuests.add(m.quest);
}

const SIDES = {
  Horde: { Orc: 2, Undead: 16, Tauren: 32, Troll: 128, Skyborne: 2 ** 33 },
  Alliance: { Human: 1, Dwarf: 4, NightElf: 8, Gnome: 64, Skyborne: 2 ** 32 },
};
const RACES = SIDES[FACTION];
const CLASSES = { Warrior: 1, Paladin: 2, Hunter: 4, Rogue: 8, Priest: 16, Shaman: 64, Mage: 128, Warlock: 256, Druid: 1024 };
const hasBit = (mask, bit) => Math.floor(mask / bit) % 2 === 1;
const ALL_CLASSES = Object.values(CLASSES).reduce((a, b) => a + b, 0);

const raceNames = (q) => {
  if (q.races == null || q.races === 0) return null;
  const names = Object.entries(RACES).filter(([, bit]) => hasBit(q.races, bit)).map(([n]) => n);
  return names.length === Object.keys(RACES).length ? null : names;
};
const classNames = (q) => {
  if (q.classes == null || q.classes === 0 || (q.classes & ALL_CLASSES) === ALL_CLASSES) return null;
  return Object.entries(CLASSES).filter(([, bit]) => q.classes & bit).map(([n]) => n);
};
const openToSide = (q) => { const r = raceNames(q); return r === null || r.length > 0; };

const oldOnly = (q) => { const s = q.source || []; return !s.includes('questie-forever') && !s.includes('polestar-correction'); };
// A quest's reputation needs. The battlegrounds' factions come from playing them: that is PvP, not a quest list.
const repsOf = (q) => {
  const best = new Map();
  for (const r of [q.reputation, q.minRep]) if (r && (!best.has(r.faction) || (r.value ?? 0) > best.get(r.faction).value)) best.set(r.faction, { faction: r.faction, value: r.value ?? 0 });
  return [...best.values()];
};
const BATTLEGROUND_FACTIONS = new Set([509, 510, 709, 729, 730, 889, 890, 2798]);
// The client does not mark every battleground quest as PvP: its area says so (Warsong Gulch, Arathi Basin,
// Alterac Valley, Darkspear Islands).
const BATTLEGROUND_AREAS = new Set([3277, 3358, 2597, 16606]);
const inBattleground = (q) => BATTLEGROUND_AREAS.has(q.area) || BATTLEGROUND_AREAS.has(questArea[q.id]);
// Quests Forge's solo filter leaves out by hand, each with its reason; an elite stays, a level 60 may manage it.
const listedOut = new Map();
for (const e of JSON.parse(fs.readFileSync(path.join(clone, 'rust/crates/forge-world/src/solo-overrides.json'), 'utf8')).exclude) {
  if (e.category === 'elite') continue;
  const why = e.category === 'pvp' ? 'pvp' : `listed by Polestar: ${e.reason}`;
  for (const id of e.ids) {
    if (Array.isArray(id)) for (let i = id[0]; i <= id[1]; i++) listedOut.set(i, why);
    else listedOut.set(id, why);
  }
}
// The Scourge Invasion's mobs. The data marks some of its quests as the event's (17), not the ones started by
// an item only these mobs drop (the "... from the Front" letters).
const INVASION_EVENT = 17;
const INVASION_MOBS = new Set([16141, 16143, 16298, 16299, 16379, 16380, 16383]);
const startedByInvasion = (q) => (q.start?.item || []).some((id) => {
  const droppers = Object.keys(items[id]?.drops?.npc || {}).map(Number);
  return droppers.length > 0 && droppers.every((n) => INVASION_MOBS.has(n)) && !Object.keys(items[id]?.drops?.object || {}).length;
});
const eventOf = (q) => q.event || (startedByInvasion(q) ? INVASION_EVENT : null);
// What other quests give, for an objective no mob or object is known to drop.
const rewardedBy = new Map();
for (const line of fs.readFileSync(path.join(clone, 'forever-db/data/quest_reward.jsonl'), 'utf8').split('\n')) {
  if (!line) continue;
  const r = JSON.parse(line);
  if (r.kind === 'item' || r.kind === 'choice') (rewardedBy.get(r.id) || rewardedBy.set(r.id, []).get(r.id)).push(r.quest);
}
const noSourceHint = (itemId) => {
  const titles = [...new Set((rewardedBy.get(itemId) || []).filter((id) => quests[id] && openToSide(quests[id])).map((id) => quests[id].title))];
  if (!titles.length) return 'Not from a mob or object the data knows: a crafter or the auction house may have it. Skip this quest if you cannot get it.';
  const named = titles.slice(0, 3).join(', ');
  return `Reward of another quest: ${named}${titles.length > 3 ? ', ...' : ''}. Skip this quest if you do not want to do that.`;
};
// A boss of the open world (rank 3, level 60 and up, in no instance, no faction's friend) takes a raid. An item only such bosses drop,
// to start a quest or for its objective, makes the quest raid content whatever the client calls it. Not a
// `kill` objective: friendly leaders are rank 3 too, and killing them there means talking to them.
const worldBoss = (id) => { const n = npcs[id]; return !!n && n.rank === 3 && (n.level || 0) >= 60 && !n.faction && !codexNpcs[id]?.instance; };
const droppedByWorldBosses = (itemId) => {
  const droppers = Object.keys(items[itemId]?.drops?.npc || {});
  return droppers.length > 0 && droppers.every(worldBoss) && !Object.keys(items[itemId]?.drops?.object || {}).length;
};
const needsWorldBoss = (q) => (q.start?.item || []).some(droppedByWorldBosses) || (q.objectives || []).some((o) => o.type === 'item' && droppedByWorldBosses(o.id));
// Quests the game does not offer though the data holds them: from reports in the game.
const knownOut = JSON.parse(fs.readFileSync(path.join(PACK, 'tools/known-out.json'), 'utf8')).quests;
const startKnown = (q) => ['npc', 'object', 'item'].some((k) => (q.start?.[k] || []).length);
const endKnown = (q) => ['npc', 'object'].some((k) => (q.end?.[k] || []).length);
const PLACEHOLDER = /<[^>]*>|^\[|\bUNUSED\b|\bNYI\b|\bDEPRECATED\b|\(123\)|\btest quest\b|DND FLAG/i;
const isleZones = new Set();
for (const set of Object.values(frames)) for (const [z, f] of Object.entries(set)) if (f.c === 2991) isleZones.add(z);
const onIsle = (rec) => { const zs = Object.keys(rec?.spawns || {}); return zs.length > 0 && zs.every((z) => isleZones.has(z)); };
const refOnIsle = (ref) => (ref?.npc || []).some((id) => onIsle(npcs[id])) || (ref?.object || []).some((id) => onIsle(objects[id]));

const hasSpawns = (rec) => Object.keys(rec?.spawns || {}).length > 0;
const insideOf = (kind, id, q) => {
  if (kind === 'npc' && codexNpcs[id]?.instance) return instanceByKey.get(codexNpcs[id].instance) || null;
  return instanceOfQuest.get(q.id) || null;
};
// A quest target's place: its spawns, else the entrance of the instance it stands in.
function refPlaced(ref, q) {
  for (const [kind, table] of [['npc', npcs], ['object', objects]]) {
    for (const id of ref?.[kind] || []) {
      if (hasSpawns(table[id])) return true;
      if (atEntrance(insideOf(kind, id, q))) return true;
    }
  }
  return false;
}
// The modifiers a goal needs when its target has no spawn of its own.
function placeFor(ref, q) {
  for (const [kind, table] of [['npc', npcs], ['object', objects]]) for (const id of ref?.[kind] || []) if (hasSpawns(table[id])) return '';
  for (const [kind] of [['npc'], ['object']]) for (const id of ref?.[kind] || []) { const m = atEntrance(insideOf(kind, id, q)); if (m) return ` ${m}`; }
  return '';
}

// What blocks a quest: every id in `all` handed in, and one of `any` (Forge's prereqs.rs).
function blocking(q) {
  const never = new Set([q.id, ...(q.excl || [])]);
  if (q.parent) never.add(q.parent);
  const isCrumb = (p) => (q.breadcrumbs || []).includes(p) || quests[p]?.breadcrumbFor === q.id;
  const blocks = (p) => {
    if (never.has(p) || isCrumb(p)) return false;
    const pq = quests[p];
    if (!pq) return true;
    return !(pq.excl || []).includes(q.id) && startKnown(pq) && !oldOnly(pq);
  };
  const split = q.preAll != null || q.preAny != null;
  const all = split ? (q.preAll || []).filter(blocks) : [];
  const group = split ? q.preAny || [] : q.pre || [];
  const any = group.some(isCrumb) ? [] : group.filter(blocks);
  return { all, any };
}

function reasonOut(q) {
  if (!openToSide(q)) return 'other faction';
  if (PLACEHOLDER.test(q.title || '')) return 'placeholder, not a real quest';
  if (knownOut[q.id]) return knownOut[q.id];
  if (oldOnly(q)) return 'only in the old database, not in the data of the game';
  if (q.skill || /^Craftsman's Writ/.test(q.title || '')) return 'profession';
  if (listedOut.has(q.id) && listedOut.get(q.id) !== 'pvp') return listedOut.get(q.id);
  if (refOnIsle(q.start) || refOnIsle(q.end)) return 'Zephras Isle: its own race, and the way back at 60 is unknown';
  if (!startKnown(q)) return 'no giver in the data';
  if (!endKnown(q)) return 'no turn-in in the data';
  // Started by an item nothing is known to give: a promotion's voucher, a drop the data lacks.
  if (!(q.start?.npc || []).length && !(q.start?.object || []).length) {
    const sourced = (q.start?.item || []).some((id) => { const it = items[id]; return it && (Object.keys(it.drops?.npc || {}).length || Object.keys(it.drops?.object || {}).length || (it.vendors || []).length); });
    if (!sourced) return 'started by an item with no known source';
  }
  if (!refPlaced(q.start, q) && (q.start?.npc?.length || q.start?.object?.length)) return 'giver has no place in the data';
  if (!refPlaced(q.end, q)) return 'turn-in has no place in the data';
  if (q.repeatable) return 'repeatable';
  return null;
}

// First pass, then what only a left-out quest opens goes too. A repeatable another quest needs stays.
const reason = new Map();
const scope = new Map();
for (const q of Object.values(quests)) {
  const r = reasonOut(q);
  if (r) reason.set(q.id, r);
  else scope.set(q.id, q);
}
let grew = true;
while (grew) {
  grew = false;
  for (const q of scope.values()) {
    const { all, any } = blocking(q);
    for (const p of [...all, ...any]) {
      if (reason.get(p) === 'repeatable' && quests[p]) { reason.delete(p); scope.set(p, quests[p]); grew = true; }
    }
  }
}
grew = true;
while (grew) {
  grew = false;
  for (const q of [...scope.values()]) {
    const { all, any } = blocking(q);
    const missing = all.find((p) => !scope.has(p)) ?? (any.length && !any.some((p) => scope.has(p)) ? any[0] : undefined);
    if (missing !== undefined) {
      reason.set(q.id, `behind quest ${missing} (${quests[missing]?.title || 'unknown'}), itself left out`);
      scope.delete(q.id);
      grew = true;
    }
  }
}

// The order of the catalog: a quest's blockers and breadcrumbs first; by zone, then level, otherwise.
const zoneOfRef = (ref) => {
  for (const [kind, table] of [['npc', npcs], ['object', objects]]) {
    for (const id of ref?.[kind] || []) {
      const z = Object.keys(table[id]?.spawns || {})[0];
      if (z) return Number(z);
    }
  }
  return null;
};
const homeZone = (q) => (q.zone > 0 ? q.zone : null) ?? zoneOfRef(q.start) ?? zoneOfRef(q.end) ?? 0;
const crumbsOf = new Map();
for (const q of scope.values()) {
  const t = q.breadcrumbFor;
  if (t && scope.has(t)) (crumbsOf.get(t) || crumbsOf.set(t, []).get(t)).push(q.id);
}
const list = [...scope.values()].sort((a, b) => homeZone(a) - homeZone(b) || (a.level || 0) - (b.level || 0) || a.id - b.id);
const placed = new Set();
const ordered = [];
let pending = list;
while (pending.length) {
  const later = [];
  let moved = false;
  for (const q of pending) {
    const { all, any } = blocking(q);
    const ready = all.every((p) => placed.has(p)) && (!any.length || any.some((p) => placed.has(p))) && (crumbsOf.get(q.id) || []).every((c) => placed.has(c));
    if (ready) { placed.add(q.id); ordered.push(q); moved = true; } else later.push(q);
  }
  if (!moved) { for (const q of later) { placed.add(q.id); ordered.push(q); } console.warn(`generate: ${later.length} quests in a chain cycle, kept in place`); break; }
  pending = later;
}

// ---------------------------------------------------------------- .guide text
const text = (s) => String(s ?? '').replace(/"/g, "'").replace(/[\r\n\t]+/g, ' ').replace(/ -- /g, ' - ').replace(/(^|\s)#/g, '$1').replace(/\s+/g, ' ').trim();
const quote = (s) => `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
const zoneLine = (z) => (z ? `zone map ${z}` : null);

function nameOfRef(ref) {
  for (const [kind, table] of [['npc', npcs], ['object', objects]]) for (const id of ref?.[kind] || []) if (table[id]?.name) return table[id].name;
  return null;
}

const stats = { steps: 0, itemStart: 0, unplacedEvent: 0, noSource: 0 };
let stepLog = [];
let stepKind = 'A';
const notes = [];

function questLines(q) {
  const out = [];
  const only = [...(classNames(q) || []), ...(raceNames(q) || [])];
  const onlyLine = only.length ? `  only ${only.join(',')}` : null;
  const step = (title, zone, lines) => {
    out.push('', `step ${text(title)}`);
    const z = zoneLine(zone);
    if (z) out.push(`  ${z}`);
    if (onlyLine) out.push(onlyLine);
    for (const l of lines) out.push(`  ${l}`);
    stats.steps++;
    stepLog.push([q.id, stepKind]);
  };

  // The accept: from its giver, or from the item that starts it.
  stepKind = 'A';
  const startItem = (q.start?.item || [])[0];
  if (!(q.start?.npc || []).length && !(q.start?.object || []).length && startItem) {
    stats.itemStart++;
    const it = items[startItem];
    const known = it && (Object.keys(it.drops?.npc || {}).length || Object.keys(it.drops?.object || {}).length || (it.vendors || []).length);
    step(it?.name || q.title, null, known
      ? [`collect ${startItem} x1`, `accept ${q.id} item ${startItem}`]
      : [`accept ${q.id} item ${startItem}`]);
    if (!known) notes.push({ quest: q.id, title: q.title, what: `starting item ${startItem} has no known source` });
  } else {
    step(nameOfRef(q.start) || q.title, zoneOfRef(q.start), [`accept ${q.id}${placeFor(q.start, q)}`]);
  }

  // The objectives, numbered as the quest log lists them.
  stepKind = 'W';
  (q.objectives || []).forEach((o, i) => {
    const n = i + 1;
    const count = Number(o.count) > 0 ? ` x${Number(o.count)}` : '';
    const inst = instanceOfQuest.get(q.id) || (o.type === 'kill' && codexNpcs[o.id]?.instance ? instanceByKey.get(codexNpcs[o.id].instance) : null);
    if (o.type === 'kill') {
      const place = hasSpawns(npcs[o.id]) ? '' : atEntrance(inst);
      if (!hasSpawns(npcs[o.id]) && !place) notes.push({ quest: q.id, title: q.title, what: `kill target ${o.id} (${npcs[o.id]?.name || '?'}) has no place` });
      step(npcs[o.id]?.name || q.title, null, [`kill ${o.id}${count} quest ${q.id}.${n}${place ? ` ${place}` : ''}`]);
    }
    else if (o.type === 'object') {
      const place = hasSpawns(objects[o.id]) ? '' : atEntrance(inst);
      if (!hasSpawns(objects[o.id]) && !place) notes.push({ quest: q.id, title: q.title, what: `object ${o.id} (${objects[o.id]?.name || '?'}) has no place` });
      step(objects[o.id]?.name || q.title, null, [`interact ${o.id} quest ${q.id}.${n}${place ? ` ${place}` : ''}`]);
    }
    else if (o.type === 'item') {
      const it = items[o.id];
      const has = it && (Object.keys(it.drops?.npc || {}).length || Object.keys(it.drops?.object || {}).length || (it.vendors || []).length);
      const placedSource = it && [...Object.keys(it.drops?.npc || {}).map((id) => npcs[id]), ...Object.keys(it.drops?.object || {}).map((id) => objects[id]), ...(it.vendors || []).map((id) => npcs[id])].some(hasSpawns);
      const place = placedSource ? '' : atEntrance(inst);
      if (!has) { stats.noSource++; notes.push({ quest: q.id, title: q.title, what: `objective item ${o.id} (${it?.name || '?'}) has no known source` }); }
      else if (!placedSource && !place) notes.push({ quest: q.id, title: q.title, what: `objective item ${o.id} (${it?.name || '?'}) comes from nothing with a place` });
      const hint = has ? '' : ` -- ${text(noSourceHint(o.id))}`;
      step(it?.name || q.title, null, [`collect ${o.id}${count} quest ${q.id}.${n}${place ? ` ${place}` : ''}${hint}`]);
    } else if (o.type === 'event') {
      if (o.x != null && o.y != null && o.map) {
        const frame = o.f === 'l' ? ' live' : ' era';
        step(text(o.text) || q.title, o.map, [`goto ${o.x},${o.y} ${quote(text(o.text) || q.title)}${frame}`]);
      } else {
        stats.unplacedEvent++;
        notes.push({ quest: q.id, title: q.title, what: `objective with no place: ${text(o.text)}` });
      }
    }
  });

  stepKind = 'T';
  step(nameOfRef(q.end) || q.title, zoneOfRef(q.end), [`turnin ${q.id}${placeFor(q.end, q)}`]);
  return out;
}

// ---------------------------------------------------------------- write
const slug = FACTION.toLowerCase();
const catalogDir = path.join(PACK, 'guides', 'catalog');
fs.mkdirSync(catalogDir, { recursive: true });
for (const f of fs.readdirSync(catalogDir)) if (f.startsWith(`${slug}-catalog-`)) fs.rmSync(path.join(catalogDir, f));
const chosen = ONLY_ZONES ? ordered.filter((q) => ONLY_ZONES.has(homeZone(q))) : ordered;
const parts = [];
for (let i = 0; i < chosen.length; i += PER_GUIDE) parts.push(chosen.slice(i, i + PER_GUIDE));
const stepLogs = [];
parts.forEach((part, i) => {
  stepLog = [];
  const num = String(i + 1).padStart(2, '0');
  const id = `${PACK_ID}/${slug}-catalog-${num}`;
  const lines = [
    '# Generated by tools/generate.js from the reference data. Do not edit: fix the generator or the data.',
    `guide ${id}`,
    `title Every Quest, ${FACTION} catalog ${i + 1}`,
    'category Miscellaneous',
    `faction ${FACTION}`,
    'levels 60-60',
    `zone map ${homeZone(part[0]) || 1411}`,
  ];
  if (i + 1 < parts.length) lines.push(`next ${PACK_ID}/${slug}-catalog-${String(i + 2).padStart(2, '0')}`);
  for (const q of part) lines.push(...questLines(q));
  fs.writeFileSync(path.join(catalogDir, `${slug}-catalog-${num}.guide`), `${lines.join('\n')}\n`);
  stepLogs.push({ id, steps: stepLog });
});

// The published list.
const scopeDir = path.join(PACK, 'scope');
fs.mkdirSync(scopeDir, { recursive: true });
const excludedRows = [...reason.entries()]
  .filter(([, r]) => r !== 'other faction')
  .map(([id, r]) => ({ id, title: quests[id]?.title ?? null, level: quests[id]?.level ?? null, reason: r }))
  .sort((a, b) => a.id - b.id);
fs.writeFileSync(path.join(scopeDir, `excluded-${slug}.json`), `${JSON.stringify(excludedRows, null, 1)}\n`);
const kinds = {};
for (const q of scope.values()) { const k = questKind(q); kinds[k] = (kinds[k] || 0) + 1; }
const byReason = {};
for (const r of excludedRows) { const k = r.reason.startsWith('behind quest') ? 'behind a left-out quest' : r.reason; byReason[k] = (byReason[k] || 0) + 1; }
const summary = [
  `# Every Quest, ${FACTION}: the list`,
  '',
  `${scope.size} quests across every ${FACTION} race and class.`,
  '',
  '| Kind | Quests |',
  '|---|---|',
  ...Object.entries(kinds).sort((a, b) => b[1] - a[1]).map(([k, n]) => `| ${k} | ${n} |`),
  '',
  '## Left out',
  '',
  '| Reason | Quests |',
  '|---|---|',
  ...Object.entries(byReason).sort((a, b) => b[1] - a[1]).map(([k, n]) => `| ${k} | ${n} |`),
  '',
  `Each quest and its reason: excluded-${slug}.json.`,
  '',
];
fs.writeFileSync(path.join(scopeDir, `summary-${slug}.md`), summary.join('\n'));
fs.writeFileSync(path.join(scopeDir, `data-gaps-${slug}.json`), `${JSON.stringify(notes, null, 1)}\n`);
const meta = {};
for (const q of chosen) {
  const { all, any } = blocking(q);
  meta[q.id] = { kind: questKind(q), level: q.level ?? null, all, any, crumbs: crumbsOf.get(q.id) || [], excl: (q.excl || []).filter((x) => scope.has(x)), instance: instanceOfQuest.get(q.id)?.key ?? null, reps: repsOf(q).map((r) => [r.faction, r.value ?? 0]), event: eventOf(q), maxLevel: q.maxLevel || null, next: q.next && scope.has(q.next) ? q.next : null, races: raceNames(q), classes: classNames(q), tight: tightQuests.has(q.id) || !!q.escort, title: q.title };
}
fs.writeFileSync(path.join(scopeDir, `quests-${slug}.json`), JSON.stringify(meta));
fs.writeFileSync(path.join(scopeDir, `steps-${slug}.json`), JSON.stringify(stepLogs));

console.log(`generate: ${chosen.length} of ${scope.size} quests in ${parts.length} guides, ${stats.steps} steps; item starts ${stats.itemStart}, objective items with no source ${stats.noSource}, objectives with no place ${stats.unplacedEvent}`);
console.log('kinds', kinds);
console.log('left out', byReason);
