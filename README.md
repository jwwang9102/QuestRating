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
- items per loot from the server's loot tables (a termite mound gives 1-20 termites), and the camp with the
  shortest time when the nearest one would make you wait for respawns;
- picking up objects: the object's own respawn time and the chance it gives the item; objects sharing the same
  spawn points (the Un'Goro crystals) are gathered in one sweep;
- orange quests (3 or 4 levels above you): fight and rest +25 % / +50 % (+2 / +5 s rest per kill when you
  never rest); deaths are not counted;
- random drops are not farmed: the item that starts the quest, or a drop that 32+ creature types give at
  under 15 % (the Green Hills pages, OOX beacons), takes no time; such a quest is not rated until you hold the
  item (不評分: "需要隨機掉落的物品，拿到後才評分");
- quest XP from the client's QuestXP table (WoW Forever build 1.60.1.71139);
- one level range for every calculation (route sharing, chains, dungeon companions, maps): quests at full XP
  (not 6+ levels below you), at most 4 levels above you, and below max level no level-60 quest. A quest 5+
  levels above you is always 很低 ("超過等級範圍");
- route sharing: only with nearby quests in your level range that are not rated 很低 themselves (their chain
  value counted);
- mobs on the way: cleared when dense; elites only when their area reaches the quest's own points (an elite
  area you fight into), not those passed on the way;
- escorts: the escorted NPC's path and walking speed;
- your own pace: your measured solo fight time (once there are 5 fights) and your rest per kill, recorded
  in game. Rest is the time you stand still out of combat between two solo fights with health (or mana)
  below full, the loot window closed, whatever else you do meanwhile; it is the mean over your newest 60
  kills, and below 30 kills the missing ones take your character's mean over all levels, else the default
  (3 s per kill, from WoW Forever questing videos). A kill costs fight + loot + rest + the walk to it;
- walking between targets: the spacing of the camp's spawn points; a stealthed target (stealth aura in the
  server data) is not seen from afar, so its points are walked to in turn;
- travel: walking, or a flight when quicker (walk to a flight master of your faction, the flight along the
  client's flight paths from OneForAll's data, walk on; a map without a flight point uses the nearest ones;
  every flight point is taken as already learned),
  or a ship (between the continents, Rut'theran - Auberdine, Grom'gol - Undercity; to and from the docks
  walking or flying as any leg). You ride once you have riding (a WoW Forever mount quest turned in, a riding
  skill, or mounted now), else walk. Walks go around mountains, cliffs and city
  walls traced on the zone maps, swim across water at swimming speed, cross rock-pillar ground at 70 % speed,
  and pass between zones through their connections. On foot the hostile mobs within
  20 yd of the way that cannot be slipped past (another one within 40 yd) are fought, and at a camp the other
  hostile mobs beside the targets are cleared along with them, mounted or not;
- shared route: in the rating, nearby quests you can do along the way, including ones you have not taken
  yet, share the trip (ships and long deliveries too); the tooltip shows the quest's whole time;
- quests already in your log are updated by progress; accepting gives no discount;
- a quest with an elite target (and the server's group quests) is rated for a party of 3-5 players and
  tagged "建議組隊": items needed x the party, fights shared;
- dungeon quests are rated as a run: a route-based run time, shared with the other quests of the same
  run; what one run does not finish is caught up by the most efficient option; the trip to the dungeon
  is not counted. A quest whose remaining objectives are all
  outside is rated as an ordinary quest; when every objective can be done inside or outside, the more
  efficient way is used and named in the reasons. Taking, an objective or turning in inside the dungeon
  makes it a dungeon quest. Objectives in several dungeons are not estimated;
- once your character is at max level, every quest is rated by its rewards per hour of its time: gold
  0-5 (money at max level plus the best vendor price of the reward items), gear 0-20 (the reward against what
  you wear, by OneForAll's Gear Value; full points at the slot's blue best-in-slot for your spec, from community
  pre-raid lists), reputation 0-10, key quests 20 (every member needs it) or 10 (dungeon key, new reputation
  or system), ranked against all quests; an attunement stays the best rating and a key quest further on in the
  chain adds +2, a dungeon key or new system is at least 高. Capital-city reputation counts at a quarter. A
  quest whose time cannot be estimated is ranked on its points alone, and a max-level quest (Tier 0.5 and the
  like) always is, among the max-level quests; a quest whose money and reputation are in
  no source (most WoW Forever additions) is not rated unless it has gear or key points;
- a quest left out for no or almost no XP is rated after all when it has a reward besides gold (a key quest,
  reputation, or a reward item that is an upgrade for you);
- key quests: an attunement every member needs (Onyxia's Drakefire Amulet chain) and a quest that
  teaches a new skill (class spells, profession ranks; not recipes) are rated best; a dungeon key (one
  per group), a new reputation or a new system (camping, riding) gives +2 levels. Plain turn-ins and
  reputation gains get nothing;
- holiday quests are rated but left out of the standards;
- quests that give no XP, or almost none at your level (less than a tenth of the median quest XP of the
  quests you can take at your level) and open no other quest, are not rated below max level (shown as 不評) and are left out of
  the standards and the map recommendation;
- a quest in a chain (next in chain, offered right after, the next quest needs it, or a breadcrumb /
  delivery to the quest it leads to; not an opener of three or more quests or a quest any one of three or more lines leads to; into dungeons too)
  is ranked by its whole chain; at a choice of two each branch is its own
  route, the quests before it take the better one; quests you have done are left out; a follow-up with an
  upgrade reward (with OneForAll) or a key quest adds its bonus. The tooltip lists the follow-ups, each
  with its own rating (the quest alone) and reasons;

Data reliability: drop rates come from Classic emulator data and may differ from the real game. A group
quest needing more than one of an item counts one per corpse (each member needs their own) unless the item
is known to drop for every member.

Recommendations:

- dungeons: one run's kill XP plus the dungeon quests you can do in it, per hour of the run itself (the
  trip there is not counted; dungeon kill XP 60 %), rated like a map: as R against grinding on the map
  standard at your pace. The run time is measured from real clears and does not change with your pace. The
  level range is the game's dungeon finder range; outside it the dungeon is shown as not recommended. Shown
  in OneForAll's dungeon map pin tooltips (needs OneForAll) and listed by `/qr dungeons`;
- dungeons: a wing's run with its quests you can still do, plus their follow-ups that are talks or one short
  fight (e.g. the Platinum Discs, The Unsent Letter -> Bazil Thredd, Marshal Windsor's chain back to the
  Stormwind events), cut where a step needs another fighting area or dungeon;
- maps: all the rated open-world quests you can take on a zone map at full XP (not 6+ levels below you), at
  most 4 levels above you, never a level-60 quest and none that needs a random drop you do not hold, grouped into hubs (each quest with the
  time its own rating uses, plus a walk between them inside a hub and a tour between hubs). Their XP over
  their hours and walks, times the quantity H / (H + trip): H the hours of the quests rated 中 or better
  (their own time), the trip from the map you are on (main hub to main hub, walking or riding, flights and ships;
  on the map itself only the way out, to the nearest flight master or map; left out inside a dungeon), is rated as R against grinding on the map standard at your pace: the quests' standard with
  its band edges times the typical reductions of a map, its quests' concentration (the walks between them) and
  quantity (the trip), each the median over all maps and levels, on foot or mounted as you travel. Maps are
  not compared with each other, and a map whose good quests take about as long as getting there is worth half its rate. A
  map with open quests but none rated 中 or better is 很低. Maps more than 4 levels above you or without XP
  are not rated. Shown on the world map under OneForAll's zone level, and after the level when hovering a
  zone on a continent map.

Where it shows: Questie's tracker (the rating only; hover the quest title for the reasons) and map icon
tooltips, the world map quest log, the quest offer window, and the quest log and map quest detail pages
(rating and every reason under the title). Questie and OneForAll are optional.

## Install

Copy or clone this folder into `World of Warcraft/_forever_/Interface/AddOns/QuestRating`.

## Commands

- `/qr` (or the minimap button) opens a window with your measured pace (fight time, rest, records per
  level) and the settings; drag the button to move it around the minimap.
- `/qr log` lists the rating of every quest in your log.
- `/qr debug <questID>` prints each step of the calculation.
- `/qr dungeons` lists the dungeon recommendations and the dungeon finder's level ranges.

## Data and license

`Data/Generated.lua` is generated offline from ForeverDB (GPL-3.0) and the TrinityCore Forever world
database (GPL-2.0), plus QuestieDB quest XP. This addon is released under the GPL-3.0 (see `LICENSE`).
