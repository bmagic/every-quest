#!/usr/bin/env node
'use strict';
// The release zip: what tools/build.js builds, planner included. `forge release pack` must not be used for this addon:
// it packs the catalog alone, as guides players would see, without the planner.
//
//   node tools/release.js <polestar clone>      writes release/PolestarPack_EveryQuest-<version>.zip
//
// The zip is committed: a build needs the game's client, so GitHub cannot make it, and the tag's workflow publishes this
// one (.github/workflows/release.yml). The folder holds the current version's only. The same files give the same zip:
// entries are sorted and carry a fixed date.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { execFileSync } = require('node:child_process');

const clone = path.resolve(process.argv[2] || '../polestar');
const PACK = path.resolve(__dirname, '..');
const FOLDER = 'PolestarPack_EveryQuest';
const out = path.join(PACK, 'dist', FOLDER);
const { version } = JSON.parse(fs.readFileSync(path.join(PACK, 'pack.json'), 'utf8'));

execFileSync(process.execPath, [path.join(__dirname, 'build.js'), clone], { stdio: 'inherit' });

// A zip without the planner, or one for another version, must not leave this machine.
const toc = fs.readFileSync(path.join(out, `${FOLDER}.toc`), 'utf8');
if (!toc.includes(`## Version: ${version}\n`)) throw new Error(`the .toc does not say version ${version}`);
const inToc = toc.split('\n').filter((l) => l.endsWith('.lua'));
for (const f of ['Data.lua', 'Core.lua', 'Plan.lua', 'Meta-Horde.lua', 'Meta-Alliance.lua', 'Catalog-Horde.lua', 'Catalog-Alliance.lua', 'Addon.lua', 'Options.lua']) {
  if (!inToc.includes(f)) throw new Error(`the .toc does not load ${f}`);
}
for (const f of [...inToc, 'LICENSE.txt', 'LICENSE-DATA.txt', 'NOTICE.txt']) {
  if (!fs.existsSync(path.join(out, f))) throw new Error(`${f} is missing from ${out}`);
}
for (const f of fs.readdirSync(out)) {
  if (f.endsWith('.lua') && !inToc.includes(f)) throw new Error(`${f} is in ${out} but the .toc does not load it`);
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};

const DOS_DATE = (1 << 5) | 1; // 1 January 1980, the first date a zip can hold
const u16 = (n) => { const b = Buffer.alloc(2); b.writeUInt16LE(n); return b; };
const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b; };
const common = (crc, packed, size, name) => [u16(20), u16(0), u16(8), u16(0), u16(DOS_DATE), u32(crc), u32(packed), u32(size), u16(name.length), u16(0)];

const parts = [];
const directory = [];
let offset = 0;
for (const file of fs.readdirSync(out).sort()) {
  const data = fs.readFileSync(path.join(out, file));
  const packed = zlib.deflateRawSync(data, { level: 9 });
  const name = Buffer.from(`${FOLDER}/${file}`);
  const crc = crc32(data);
  const local = Buffer.concat([u32(0x04034b50), ...common(crc, packed.length, data.length, name), name]);
  parts.push(local, packed);
  directory.push(Buffer.concat([u32(0x02014b50), u16(20), ...common(crc, packed.length, data.length, name), u16(0), u16(0), u16(0), u32(0), u32(offset), name]));
  offset += local.length + packed.length;
}
const central = Buffer.concat(directory);
const end = Buffer.concat([u32(0x06054b50), u16(0), u16(0), u16(directory.length), u16(directory.length), u32(central.length), u32(offset), u16(0)]);
const releaseDir = path.join(PACK, 'release');
fs.rmSync(releaseDir, { recursive: true, force: true });
fs.mkdirSync(releaseDir, { recursive: true });
const zip = path.join(releaseDir, `${FOLDER}-${version}.zip`);
fs.writeFileSync(zip, Buffer.concat([...parts, central, end]));
console.log(`release: ${directory.length} files, ${(fs.statSync(zip).size / 1024 / 1024).toFixed(2)} MiB -> ${zip}`);
