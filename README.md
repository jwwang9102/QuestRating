# QuestRating

A World of Warcraft addon for the Forever client (Interface 16001) that rates quests by estimated
time efficiency: XP per hour compared with grinding mobs of your level, banded against quests of the
same level. Ratings: 很低 / 低 / 中 / 高 / 很高, each with a few short reasons. The user interface is in
Traditional Chinese (zhTW).

What goes into the estimate:

- kill and drop quests: drop rate, required count, spawn density, respawn waits, travel;
- picking up objects: the object's own respawn time and the chance it gives the item;
- escorts: the escorted NPC's path and walking speed;
- follow-up quests in the chain, dungeon quests further down the chain, and reward upgrades
  (with OneForAll).

Where it shows: Questie's tracker and map icon tooltips, the world map quest log, and the quest offer
window. Questie and OneForAll are optional.

## Install

Copy or clone this folder into `World of Warcraft/_forever_/Interface/AddOns/QuestRating`.

## Commands

- `/qr` opens the settings.
- `/qr log` lists the rating of every quest in your log.
- `/qr debug <questID>` prints each step of the calculation.

## Data and license

`Data/Generated.lua` is generated offline from ForeverDB (GPL-3.0) and the TrinityCore Forever world
database (GPL-2.0), plus QuestieDB quest XP. This addon is released under the GPL-3.0 (see `LICENSE`).
