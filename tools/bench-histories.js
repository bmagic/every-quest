#!/usr/bin/env node
'use strict';
// Histories for tests/bench.lua: which quests a simulated player has already done.
//   node tools/bench-histories.js <polestar clone> > tests/histories.lua
const fs = require('node:fs');
const path = require('node:path');

const clone = path.resolve(process.argv[2] || '../polestar');
const PACK = path.resolve(__dirname, '..');
const meta = JSON.parse(fs.readFileSync(path.join(PACK, 'scope', 'quests-horde.json'), 'utf8'));
const quests = JSON.parse(fs.readFileSync(path.join(clone, 'data/forever/quests.json'), 'utf8'));

const orc = Object.keys(meta).map(Number).filter((id) => {
  const m = meta[id];
  return (!m.races || m.races.includes('Orc')) && (!m.classes || m.classes.includes('Warrior'));
});

function rng(seed) {
  let a = seed * 7919;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Only quests whose chain is itself done count as done.
function closed(raw) {
  const done = new Set();
  let changed = true;
  const list = [...raw].filter((id) => meta[id]);
  while (changed) {
    changed = false;
    for (const id of list) {
      if (done.has(id)) continue;
      const m = meta[id];
      const all = m.all.every((p) => done.has(p) || !meta[p]);
      const any = !m.any.length || m.any.some((p) => done.has(p) || !meta[p]);
      if (all && any) { done.add(id); changed = true; }
    }
  }
  return done;
}

function route() {
  const set = new Set();
  const base = path.join(clone, 'guides/forever/horde');
  const read = (f) => { for (const l of fs.readFileSync(f, 'utf8').split('\n')) { const m = l.match(/^\s*turnin\s+(\d+)/); if (m) set.add(+m[1]); } };
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (e.name.endsWith('.guide')) read(p); } };
  for (const e of fs.readdirSync(base, { withFileTypes: true })) {
    if (e.isDirectory() && ['orc', '30-40', '40-50', '50-60'].includes(e.name)) walk(path.join(base, e.name));
    else if (e.name.endsWith('.guide')) read(path.join(base, e.name));
  }
  return set;
}
const polestar = route();

function noisy(seed, keep, extra) {
  const r = rng(seed);
  return closed(orc.filter((id) => (polestar.has(id) ? r() < keep : r() < extra)));
}
function zones(seed, zoneShare, questShare) {
  const r = rng(seed);
  const all = [...new Set(orc.map((id) => quests[id].zone))];
  const chosen = new Set(all.filter(() => r() < zoneShare));
  return closed(orc.filter((id) => chosen.has(quests[id].zone) && r() < questShare));
}

const players = [
  ['nothing done', new Set()],
  ["Polestar's Orc route, all of it", closed(polestar)],
  ["Polestar's Orc route, 90% of it", noisy(6, 0.9, 0)],
  ["Polestar's route at 85%, plus 10% of the others", noisy(9, 0.85, 0.1)],
  ['85% of the zones, 90% of their quests', zones(3, 0.85, 0.9)],
  ['60% of the zones, 85% of their quests', zones(1, 0.6, 0.85)],
];
fs.writeFileSync(path.join(PACK, 'tests', 'histories.json'), JSON.stringify(players.map(([label, done]) => ({ label, done: [...done] }))));
console.log('return {');
for (const [label, done] of players) console.log(`  { label = ${JSON.stringify(label)}, done = { ${[...done].join(',')} } },`);
console.log('}');
