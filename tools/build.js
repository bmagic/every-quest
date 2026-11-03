#!/usr/bin/env node
'use strict';
// Builds the addon into dist/: compiles the catalog, turns its guides into data the planner reads (they
// are not offered as guides), and adds the planner and what it needs to know (quests, transport).
//
//   node tools/build.js <polestar clone>      after: node tools/generate.js <polestar clone>
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const clone = path.resolve(process.argv[2] || '../polestar');
const PACK = path.resolve(__dirname, '..');
const FACTIONS = ['Horde', 'Alliance'];
const FOLDER = 'PolestarPack_EveryQuest';
const out = path.join(PACK, 'dist', FOLDER);

// From an empty folder: a file of an earlier build must not end up in a release.
fs.rmSync(out, { recursive: true, force: true });
const forge = process.env.FORGE || path.join(clone, 'rust/target/release/forge');
execFileSync(forge, ['guide', 'compile'], { cwd: PACK, stdio: ['ignore', 'ignore', 'inherit'] });

// The catalog: data for the planner, never registered as guides. A file for each faction: a character of the other
// stops at its first line.
const guides = fs.readFileSync(path.join(out, 'Guides.lua'), 'utf8');
const [guidesHead, ...sources] = guides.split(/^(?=-- Source: )/m);
const catalogOf = (faction) => sources.filter((c) => c.startsWith(`-- Source: guides/catalog/${faction.toLowerCase()}-catalog-`));
if (FACTIONS.reduce((n, f) => n + catalogOf(f).length, 0) !== sources.length) throw new Error('a guide in Guides.lua belongs to no faction');
for (const faction of FACTIONS) {
  const mine = catalogOf(faction);
  if (!mine.length) throw new Error(`no ${faction} guide in Guides.lua: run tools/generate.js`);
  fs.writeFileSync(path.join(out, `Catalog-${faction}.lua`), `${guidesHead}if not PolestarEveryQuestWants(${JSON.stringify(faction)}) then return end\n\n${mine.join('').split('Polestar.RegisterGuide(').join('PolestarEveryQuestCatalog(')}`);
}
fs.rmSync(path.join(out, 'Guides.lua'));

// What the planner knows about each quest and each catalog step.
const lua = (v) => {
  if (v === null || v === undefined) return 'nil';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return `{${v.map(lua).join(',')}}`;
  return `{${Object.entries(v).filter(([, x]) => x !== null && x !== undefined).map(([k, x]) => `${/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(k) ? k : `[${/^\d+$/.test(k) ? k : JSON.stringify(k)}]`}=${lua(x)}`).join(',')}}`;
};
const quests = JSON.parse(fs.readFileSync(path.join(clone, 'data/forever/quests.json'), 'utf8'));
const factionTable = JSON.parse(fs.readFileSync(path.join(clone, 'data/forever/factions.json'), 'utf8'));
const repDir = path.join(clone, 'guides/forever/reputation');
const repFiles = fs.readdirSync(repDir).filter((f) => f.endsWith('.guide')).map((f) => fs.readFileSync(path.join(repDir, f), 'utf8'));

for (const faction of FACTIONS) {
  const slug = faction.toLowerCase();
  const meta = JSON.parse(fs.readFileSync(path.join(PACK, 'scope', `quests-${slug}.json`), 'utf8'));
  const steps = JSON.parse(fs.readFileSync(path.join(PACK, 'scope', `steps-${slug}.json`), 'utf8'));
  const compact = {};
  for (const [id, m] of Object.entries(meta)) {
    const c = { kind: m.kind };
    if (m.level != null) c.level = m.level;
    if (m.all.length) c.all = m.all;
    if (m.any.length) c.any = m.any;
    if (m.crumbs.length) c.crumbs = m.crumbs;
    if (m.excl.length) c.excl = m.excl;
    if (m.reps.length) c.reps = m.reps;
    if (m.event) c.event = m.event;
    if (m.maxLevel) c.maxLevel = m.maxLevel;
    if (m.tight) c.tight = true;
    if (m.next) c.nextq = m.next;
    const target = quests[id]?.breadcrumbFor;
    if (target && meta[target]) c.crumbFor = target;
    compact[id] = c;
  }
  // The factions a quest may need, and Polestar's guide on each: the route names it where it asks to grind.
  const factions = {};
  for (const m of Object.values(meta)) for (const [f] of m.reps) factions[f] = factionTable[f]?.name || null;
  const repGuides = {};
  for (const text of repFiles) {
    const title = (text.match(/^title (.+)$/m) || [])[1];
    for (const r of text.matchAll(/^\s*rep (\d+) /gm)) if (title && factions[r[1]] !== undefined && !repGuides[r[1]]) repGuides[r[1]] = title;
  }
  const stepTable = {};
  for (const g of steps) stepTable[g.id] = g.steps;

  // The transport network, from Forge's world model of the faction. Flights and rides both name their ends by place
  // in `nodes`, from 0. (A node's own `taxi` is the game's id for its flight master: nothing here points at that.) Lua
  // counts from 1.
  const worldFile = path.join(clone, `data/sim/world-${slug}.json`);
  if (!fs.existsSync(worldFile)) throw new Error(`no ${worldFile}: forge walks world . data/local/nav4 data/sim ${slug}, in the clone`);
  const world = JSON.parse(fs.readFileSync(worldFile, 'utf8'));
  const P = world.points;
  const net = {
    nodes: world.nodes.map((n) => [P[n.pt][0], P[n.pt][2], P[n.pt][3], P[n.pt][1]]),
    taxi: world.taxi.map(([a, b, yd]) => [a + 1, b + 1, yd]),
    rides: world.rides.map((r) => [r[0] + 1, r[1] + 1, r[2] + r[3]]),
  };
  if (net.taxi.length !== world.taxi.length || net.taxi.some(([a, b, yd]) => !net.nodes[a - 1] || !net.nodes[b - 1] || !(yd > 0))) throw new Error('a flight with no ends or no length');

  fs.writeFileSync(path.join(out, `Meta-${faction}.lua`), [
    '-- Generated by tools/build.js. Do not edit.',
    `if not PolestarEveryQuestWants(${JSON.stringify(faction)}) then return end`,
    `PolestarEveryQuestMetaOf(${JSON.stringify(faction)}, {`,
    `build = ${JSON.stringify(require('node:crypto').createHash('sha1').update(JSON.stringify(stepTable)).digest('hex').slice(0, 12))},`,
    `quests = ${lua(compact)},`,
    `steps = ${lua(stepTable)},`,
    `net = ${lua(net)},`,
    `factions = ${lua(factions)},`,
    `repGuides = ${lua(repGuides)},`,
    '})',
    '',
  ].join('\n'));
}

// The planner's own files, and the addon's file list.
for (const f of ['Data.lua', 'Core.lua', 'Plan.lua', 'Addon.lua', 'Options.lua']) fs.copyFileSync(path.join(PACK, 'planner', f), path.join(out, f));
fs.copyFileSync(path.join(PACK, 'NOTICE.md'), path.join(out, 'NOTICE.txt'));
const tocFile = path.join(out, `${FOLDER}.toc`);
const toc = fs.readFileSync(tocFile, 'utf8')
  .replace(/^Guides\.lua\s*$/m, ['Data.lua', 'Core.lua', 'Plan.lua', ...FACTIONS.map((f) => `Meta-${f}.lua`), ...FACTIONS.map((f) => `Catalog-${f}.lua`), 'Addon.lua', 'Options.lua'].join('\n'))
  .replace(/^(## Dependencies: Polestar.*)$/m, '$1\n## SavedVariablesPerCharacter: PolestarEveryQuestDB');
fs.writeFileSync(tocFile, toc);
const size = (f) => (fs.statSync(path.join(out, f)).size / 1024 / 1024).toFixed(2);
for (const f of FACTIONS) console.log(`build: ${f}: ${catalogOf(f).length} catalog guides; Catalog ${size(`Catalog-${f}.lua`)} MiB, Meta ${size(`Meta-${f}.lua`)} MiB`);
console.log(`build: -> ${out}`);
