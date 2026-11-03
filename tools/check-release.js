#!/usr/bin/env node
'use strict';
// What to run before publishing a release: the tag is pack.json's version, the zip is whole and holds this very code,
// everything is committed, and the tag, once it exists, is this commit.
//
//   node tools/check-release.js v0.1.0      prints the zip's path, or says what is wrong
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const PACK = path.resolve(__dirname, '..');
const FOLDER = 'PolestarPack_EveryQuest';
const fail = (why) => {
  console.error(`check-release: ${why}`);
  process.exit(1);
};

const tag = process.argv[2];
if (!tag) fail('which tag? node tools/check-release.js v<version>');
const { version } = JSON.parse(fs.readFileSync(path.join(PACK, 'pack.json'), 'utf8'));
if (tag !== `v${version}`) fail(`the tag is ${tag}, and pack.json says version ${version}`);

const zip = path.join('release', `${FOLDER}-${version}.zip`);
if (!fs.existsSync(path.join(PACK, zip))) fail(`no ${zip}: run node tools/release.js <polestar clone>`);
const unzip = (...args) => execFileSync('unzip', args, { cwd: PACK, maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
try {
  unzip('-tqq', zip);
} catch {
  fail(`${zip} is damaged`);
}
const names = new Set(String(unzip('-Z1', zip)).trim().split('\n'));
const inZip = (f) => {
  if (!names.has(`${FOLDER}/${f}`)) fail(`${f} is not in ${zip}`);
  return unzip('-p', zip, `${FOLDER}/${f}`);
};

const toc = String(inZip(`${FOLDER}.toc`));
if (!toc.includes(`## Version: ${version}\n`)) fail(`the zip's .toc does not say version ${version}`);
const loaded = toc.split('\n').filter((l) => l.endsWith('.lua'));
for (const f of loaded) inZip(f);
for (const f of ['Meta-Horde.lua', 'Meta-Alliance.lua', 'Catalog-Horde.lua', 'Catalog-Alliance.lua', 'LICENSE-DATA.txt']) inZip(f);

// The planner and the notices, byte for byte: a zip made before the last change does not go out.
const same = [['LICENSE', 'LICENSE.txt'], ['NOTICE.md', 'NOTICE.txt']];
for (const f of fs.readdirSync(path.join(PACK, 'planner'))) {
  if (!loaded.includes(f)) fail(`the zip's .toc does not load ${f}`);
  same.push([path.join('planner', f), f]);
}
for (const [source, built] of same) {
  if (!fs.readFileSync(path.join(PACK, source)).equals(inZip(built))) fail(`${built} in the zip is not this ${source}: run node tools/release.js <polestar clone>`);
}

// The zip goes out from this machine: what it holds must be what the tag holds.
const git = (...args) => String(execFileSync('git', args, { cwd: PACK, stdio: ['ignore', 'pipe', 'ignore'] })).trim();
if (git('status', '--porcelain')) fail('commit your changes first: the release must hold the tagged code');
let tagged = null;
try {
  tagged = git('rev-parse', '--verify', '--quiet', `refs/tags/${tag}^{commit}`);
} catch {
  // Not tagged yet: this can run before tagging.
}
if (tagged && tagged !== git('rev-parse', 'HEAD')) fail(`${tag} is another commit than this one`);
console.log(zip);
