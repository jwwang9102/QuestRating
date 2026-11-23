# QuestRating

A World of Warcraft addon for the Forever client (Interface 16001) that rates quests by estimated
time efficiency: XP per hour compared with grinding mobs of your level, banded against quests of the
same level. Ratings: 很低 / 低 / 中 / 高 / 很高, each with a few short reasons. The user interface is in
Traditional Chinese (zhTW).

What goes into the estimate:

- kill and drop quests: drop rate, required count, spawn density, respawn waits, travel;
- picking up objects: the object's own respawn time and the chance it gives the item;
- escorts: the escorted NPC's path and walking speed;
- your own fight time: the median time per kill of your solo fights at your level and the two below
  (recorded in game; a default is used until there are enough fights);
- dungeon quests: a normal WoW Forever run of the dungeon (run time from Forever full-run videos, the
  mobs on the route, Forever's dungeon kill XP), shared with the other quests the same run can do;
  what one run does not finish is caught up by more runs or farming outside, whichever is quicker;
- follow-up quests in the chain and reward upgrades (with OneForAll).

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
