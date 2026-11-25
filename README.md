# QuestRating

A World of Warcraft addon for the Forever client (Interface 16001) that rates quests by estimated
time efficiency: XP per hour compared with grinding mobs of your level, banded against quests of the
same level. Ratings: 很低 / 低 / 中 / 高 / 很高, each with a few short reasons. The user interface is in
Traditional Chinese (zhTW).

How the rating works: a quest's XP per hour is compared with grinding mobs at your level, and the
quest is ranked among quests of the same level (5 bands of 20 %).

What goes into the estimate:

- kill and drop quests: expected kills (not rounded up), drop rate, required count, travel, and respawn
  waits from server data. The number of targets up is spawn points x chance (some points spawn one of
  several creatures);
- picking up objects: the object's own respawn time and the chance it gives the item;
- escorts: the escorted NPC's path and walking speed;
- your own pace: your measured solo fight time and the gap between fights (recorded in game) are used
  once there are enough samples; until then a default is used;
- shared route: nearby quests you can do along the way, including ones you have not taken yet, share
  the walks in the area; a ship or zeppelin and a delivery long enough to fly (a trip out of the area,
  such as a letter to a capital) are not shared;
- quests already in your log are updated by progress; accepting gives no discount;
- group quests are rated for a party of 3-5 players; a quest with an elite target is estimated solo and
  tagged "建議組隊";
- dungeon quests are rated as a run: a route-based run time, shared with the other quests of the same
  run; what one run does not finish is caught up by the most efficient option; the trip to the dungeon
  is not counted. A quest whose remaining objectives are all
  outside is rated as an ordinary quest; when every objective can be done inside or outside, the more
  efficient way is used and named in the reasons. Taking, an objective or turning in inside the dungeon
  makes it a dungeon quest. Objectives in several dungeons are not estimated;
- at max level XP efficiency is not rated: base 中 plus the reward and key-quest bonus (also for quests
  whose time cannot be estimated);
- key quests: an attunement every member needs (Onyxia's Drakefire Amulet chain) and a quest that
  teaches a new skill (class spells, profession ranks; not recipes) are rated best; a dungeon key (one
  per group), a new reputation or a new system (camping, riding) gives +2 levels. Plain turn-ins and
  reputation gains get nothing;
- holiday quests are rated but left out of the standards;
- quests that give no XP, or almost none at your level (less than a tenth of the median quest XP of the
  quests you can take at your level) and open no other quest, are not rated below max level (shown as 不評) and are left out of
  the standards and the map recommendation;
- a quest in a chain (next in chain, offered right after, or the next quest needs it; not a breadcrumb,
  an opener of three or more quests or a quest any one of three or more lines leads to; into dungeons too)
  is ranked by its whole chain; at a choice of two each branch is its own
  route, the quests before it take the better one; quests you have done are left out; a follow-up with an
  upgrade reward (with OneForAll) or a key quest adds its bonus. The tooltip lists the follow-ups, each
  with its own rating (the quest alone) and reasons;

Data reliability: drop rates come from Classic emulator data and may differ from the real game, and
per-member drops in a group are unknown.

Recommendations:

- dungeons: one run's kill XP plus the dungeon quests you can do in it, per hour of the run itself (the
  trip there is not counted), ranked against same-level open-world quests. The level range is the game's dungeon
  finder range; outside it the dungeon is shown as not recommended. Shown in OneForAll's dungeon map
  pin tooltips (needs OneForAll) and listed by `/qr dungeons`;
- maps: the open-world quests you can take on a zone map (quests without XP or with almost none left
  out), grouped into hubs (quests share the route inside a hub plus a walk between them; a tour between
  hubs; the trip to the map is not counted). Two ranks against the other maps that fit your level, combined so that a map weak in either is not good:
  the XP per hour of doing them all (scattered quests take longer) and how many there are. Maps more than 4 levels above you or
  without XP are not rated. Shown on the world map under OneForAll's zone level, and after the level
  when hovering a zone on a continent map.

Where it shows: Questie's tracker (the rating only; hover the quest title for the reasons) and map icon
tooltips, the world map quest log, the quest offer window, and the quest log and map quest detail pages
(rating and every reason under the title). Questie and OneForAll are optional.

## Install

Copy or clone this folder into `World of Warcraft/_forever_/Interface/AddOns/QuestRating`.

## Commands

- `/qr` opens the settings.
- `/qr log` lists the rating of every quest in your log.
- `/qr debug <questID>` prints each step of the calculation.
- `/qr dungeons` lists the dungeon recommendations and the dungeon finder's level ranges.

## Data and license

`Data/Generated.lua` is generated offline from ForeverDB (GPL-3.0) and the TrinityCore Forever world
database (GPL-2.0), plus QuestieDB quest XP. This addon is released under the GPL-3.0 (see `LICENSE`).
