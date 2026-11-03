# Notices

Every Quest is a community addon for Polestar, by Bmagic. It is not part of Polestar and its authors do not maintain
it. It is not affiliated with Blizzard Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc.

## Code

The code of this project is under the GNU General Public License, version 3 (see the licence file). It calls Polestar
in the game and copies none of its code. The skills in `.agents/` and `.claude/` come from the template of Polestar's
`polestar new`. Polestar is at https://github.com/fitzforge/polestar, under the same licence.

## Data in the addon

The data holds facts about the game (ids, names, levels, positions, quest chains), no prose from other addons.

- `Catalog-Horde.lua`, `Catalog-Alliance.lua`, `MapFrames.lua` and `Pack.lua` are produced by Polestar's compiler. `LICENSE-DATA.txt`, which the
  compiler writes next to them, lists each source, its version and its licence.
- `Meta-Horde.lua` and `Meta-Alliance.lua` are written by this project's `tools/build.js`, from the same reference data
  of a Polestar clone: quest levels, chains and reputations, faction names, and the travel network of Polestar's Forge.

## Questie

Every Quest uses the data of Questie (https://github.com/Questie/Questie) and QuestieDB
(https://github.com/Questie/QuestieDB), through Polestar's reference data. Thanks to the Questie team and its contributors.

## Data in this repository

The files `scope/excluded-*.json` and `scope/data-gaps-*.json` hold quest ids, titles and levels from the same sources.
The catalog's sources are not in the repository: `tools/generate.js` writes them from a Polestar clone's reference data.
The zip on the Releases page is the built addon, with the data listed above.
