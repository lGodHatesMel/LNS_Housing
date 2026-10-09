# Junk, Trash Bags & Garbage Bins

Houses get messy. While someone is home, junk piles up. People with a key sweep it into trash bags,
carry the bags outside and dump them in the house's garbage bin. A full bin can then be emptied by a
garbage job.

This page explains how it works, how to switch it on or off, and how to set it up.

---

## 1. Quick start

1. **Add the item.** Add a `trash_bag` item to `ox_inventory` (`ox_inventory/data/items.lua`):

   ```lua
   ['trash_bag'] = {
       label = 'Trash Bag',
       weight = 500,
       stack = true,
       close = true,
       description = 'A bag of household junk. Take it to your garbage bin.',
   },
   ```

   Add a `trash_bag.png` to `ox_inventory/web/images` if you want an inventory icon.

2. **Switch it on.** In `shared/settings.lua`:

   ```lua
   Cleaning = {
       Enabled = true,
       ...
   }
   ```

3. **Restart the resource** (`restart LNS_Housing`). Settings are read when the resource starts.
4. **Give each house a bin.** See [Placing bins](#4-placing-bins).

No SQL changes are needed. Everything is stored in each property's existing `metadata` column.

**Requirements:** `ox_lib`, `ox_target`, `ox_inventory` and `oxmysql`. The junk props are streamed from
`stream/[Props]/[Junk]` and are loaded by `fxmanifest.lua`, so there is nothing extra to install.

---

## 2. Turning it on and off

There are two switches in `shared/settings.lua` under `Cleaning`:

| Setting | Default | What it does |
|---|---|---|
| `Cleaning.Enabled` | `false` | **Master switch.** `false` turns the whole system off: no junk, no bins, no bin placement buttons in the UI, and `GetPropertyBins` returns an empty list. |
| `Cleaning.Junk.Enabled` | `true` | Only matters when the master switch is on. `false` stops junk from appearing and hides existing junk, but **bins keep working**. |

| `Cleaning.Enabled` | `Cleaning.Junk.Enabled` | Result |
|---|---|---|
| `false` | any | Everything is off. |
| `true` | `true` | Junk, trash bags and bins all work. |
| `true` | `false` | No junk. Bins can still be placed and used, and still fill up slowly by themselves. |

Notes:
- Restart the resource after changing a setting.
- Turning the system off does not delete anything. Junk and bin contents stay saved on the property and
  come back if you turn it on again.
- To stop bins filling by themselves without turning anything off, set `Bin.PassiveBagsPerHour = 0`.
- Owners can only place or move their own bin from the property tablet when `Bin.OwnerCanPlace = true`.

---

## 3. How it works

### Junk builds up

- Junk only appears in **owned houses**. Apartments and unowned properties never get junk.
- The server counts the time someone spends inside a house. Every `Junk.IntervalMinutes` (default 10) of
  occupied time, one piece of junk appears. Empty houses do not get messy.
- A house holds at most `Junk.Max` (default 10) pieces. Once it is full, the timer stops until
  something is cleaned.
- The server only saves which pieces exist and one random seed per house. Each player's game works out where
  the pieces sit from that seed, so every visitor sees the same junk in the same spots, and nothing positional is stored.
- Pieces are placed on the floor on a ring around where you enter the interior (`Junk.MinRadius` to
  `Junk.MaxRadius`), using a raycast to stay on the same floor and out of walls. The prop is chosen at
  random from `Junk.Models`.

### Sweeping it up

- Anyone with a key to the house (the owner, and anyone with entry permission) sees a **Sweep up** target on each
  piece of junk.
- Sweeping plays a broom animation and a progress bar (`Junk.CleanMs`, default 3 seconds).
- When it finishes, the piece is removed and the player gets one `trash_bag`.
- The bag is **tagged with the house it came from**.

### Bringing it outside

- Each house with a bin has a garbage bin prop outside.
- The **Dump trash bags** target on the bin moves the player's bags for that house into the bin
  (`Bin.DumpMs`). The target only shows if the player is carrying bags from that house.
- The **Check bin** target shows how full it is and when it was last emptied.
- A bin holds `Bin.Capacity` bags (default 12). When it is full it refuses more bags. The player keeps the
  rest until the bin is emptied.
- Bags pile up beside the bin as it fills: 1 bag at half full, 3 at three quarters, 4 when full.
- Bins also gain a few bags on their own over time, representing normal household waste
  (`Bin.PassiveBagsPerHour`, up to `Bin.PassiveCap`).

### Bags only count for their own house

Each `trash_bag` is created with the property ID attached, and the inventory shows "Junk from <house name>".
The bin only accepts bags tagged for its own property. Bags from another house, or from any other source
(another script, an admin command, a shop), are ignored. This means a bin can only be filled by cleaning
the house it belongs to. Bags of the same house stack together.

If `trash_bag` items existed before you installed this, they have no tag and will not be accepted by any bin.

### Emptying the bin (garbage job)

A full bin can be emptied by a garbage job. The built-in hooks are written for `ghm-garbagejob`:

- A bin becomes collectable when it holds at least `Bin.MinFillToCollect` bags (default 7) and the last
  collection was more than `Bin.CollectCooldownMinutes` ago (default 60).
- The job reserves a bin for its crew for `Bin.ClaimSeconds` so two crews do not chase the same one.
- Emptying a bin counts as `ceil(bags / BagsPerCredit)` truck bags, capped at `Bin.MaxCredit`.
- Each emptied bin also rolls the `Bin.Loot` table (see [Loot](#loot)).
- The owner gets a notification when their bin is emptied. Owners and keyholders cannot empty their own bin.

If you use a different garbage job, change `WorkerCanCollect` in `server/sv_bins.lua` to check that job instead
of `ghm-garbagejob`, then call the exports below from your job.

---

## 4. Placing bins

A bin has to stand **outside** the property: not in shell space, not in an IPL interior and not inside an
MLO's interior zone. It also has to be within `Bin.MaxDistanceFromProperty` (default 75 m) of the property
entrance.

**Agents** (real estate): open the property in **Edit Listing** and use **Garbage Bin Location**.
Choose **Place Bin** (or **Move Bin**). The tablet hides and a ghost bin follows your aim.

| Key | Action |
|---|---|
| `E` | Place the bin |
| Scroll | Rotate |
| `Backspace` | Cancel |

**Owners**: open the property tablet, go to the **Settings** tab, and use the **Garbage Bin** section to
**Place Bin**, **Move Bin** or **Remove Bin**. Placing closes the tablet. Walk outside near the property, aim at
flat ground and press `E`. The request is cancelled if the owner takes longer than
`Bin.Placement.WaitTimeout` (5 minutes). This only shows for the owner, and only when `Bin.OwnerCanPlace = true`.

Removing a bin also clears what is in it, so moving a bin cannot be used to skip the collection cooldown.

---

## 5. Settings reference

All settings are in `shared/settings.lua` under `Cleaning`.

### General and junk

| Setting | Default | Description |
|---|---|---|
| `Enabled` | `false` | Master switch for the whole system. |
| `Item` | `'trash_bag'` | The `ox_inventory` item given for swept junk and taken when dumping. |
| `Junk.Enabled` | `true` | Turns junk on or off while keeping bins. |
| `Junk.Models` | 4 props | Props used for junk pieces. One is picked at random per piece. |
| `Junk.IntervalMinutes` | `10` | Occupied minutes between new pieces. |
| `Junk.Max` | `10` | Most pieces a property can hold. |
| `Junk.CleanMs` | `3000` | Sweep time per piece, in ms. The server checks the time really passed. |
| `Junk.InteractDistance` | `2.0` | Distance at which "Sweep up" shows. |
| `Junk.Cooldown` | `750` | Minimum ms between junk requests per player. |
| `Junk.MinRadius` / `MaxRadius` | `1.5` / `6.0` | Ring around the entry point where pieces land, in metres. |

### Bins

| Setting | Default | Description |
|---|---|---|
| `Bin.Model` | `'prop_bin_07d'` | Prop used for the bin. |
| `Bin.RenderDistance` | `35.0` | Distance at which the bin spawns for a player. |
| `Bin.InteractDistance` | `3.0` | Distance at which the bin can be used (also checked by the server). |
| `Bin.MaxDistanceFromProperty` | `75.0` | How far from the entrance a bin can be placed. |
| `Bin.OwnerCanPlace` | `true` | Owners can place, move and remove their bin from the tablet. |
| `Bin.Capacity` | `12` | Bags a bin holds. |
| `Bin.DumpMs` | `1500` | Time to dump your bags. |
| `Bin.Cooldown` | `750` | Minimum ms between bin requests per player. |
| `Bin.PassiveBagsPerHour` | `1` | Bags a bin gains by itself per real hour. `0` turns this off. |
| `Bin.PassiveCap` | `3` | The bags-by-themselves trickle stops at this many. |
| `Bin.Placement.MaxDistance` | `12.0` | How far the placement ray reaches. |
| `Bin.Placement.RotateStep` | `5.0` | Degrees per scroll tick. |
| `Bin.Placement.WaitTimeout` | `300000` | Owner placement: ms to walk outside before it cancels. |

### Garbage job

| Setting | Default | Description |
|---|---|---|
| `Bin.MinFillToCollect` | `7` | Bags needed before a bin can be emptied. |
| `Bin.CollectCooldownMinutes` | `60` | Minimum time between two collections of the same bin. |
| `Bin.CollectDistance` | `4.0` | How close a worker must be to empty a bin. |
| `Bin.ClaimSeconds` | `600` | How long a crew keeps a bin reserved. |
| `Bin.BagsPerCredit` | `4` | Bags in a bin per truck bag it counts as. |
| `Bin.MaxCredit` | `3` | Most truck bags a single bin can count as. |

### Loot

When a bin is emptied the server rolls `Bin.Loot`: one roll, plus one more for every `Bin.RollsPerBags` bags
that were inside (default 4). Each entry rolls on its own.

```lua
{ item = 'plastic', min = 1, max = 4, chance = 40 },  -- chance is a percentage
```

A more expensive property raises every chance by up to `Bin.ValueBonus` (0.5 means +50%), reached at
`Bin.ValueBonusPrice` (default 1,500,000). Entries for items that do not exist in `ox_inventory` are skipped,
so the default list is safe to leave alone even if you do not have all of those items.

---

## 6. Exports and events for developers

**Server exports**

| Export | Returns |
|---|---|
| `GetPropertyBin(propertyId)` | Bin coordinates `{ x, y, z, h }`, or `nil`. |
| `GetPropertyBins()` | All bins as `{ propertyId, label, coords }`. Empty when the system is off. |
| `GetPropertyJunk(propertyId)` | Number of junk pieces in a house, or `nil` for apartments. |
| `GetPropertyOccupants(propertyId)` | Player IDs currently inside a property. |
| `GetCollectableBins(minFill?)` | Bins full enough to empty and not reserved. |
| `ClaimBin(src, propertyId, owner)` | Reserves a bin for a crew. Returns `boolean`. |
| `ReleaseBin(propertyId, owner)` | Releases a reservation. |
| `CollectBin(src, propertyId, owner)` | Empties a bin. Returns `{ ok, reason?, bags?, credit?, loot?, label? }`. |

**Client exports**

| Export | Returns |
|---|---|
| `GetBinModel()` | The bin prop model name. |
| `GetNearestBinPropertyId(coords, maxDistance?)` | Property ID of the closest spawned bin. |
| `IsBinDecoration(entity)` | `true` for the bags piled beside a bin, so a job can ignore them. |

**Server event**

`LNS_Housing:server:binEmptied` is triggered with `(propertyId, src, bags)` after a bin is emptied.

---

## 7. Safety checks

All of these happen on the server, so a modified client cannot get around them:

- Only the owner or a keyholder can sweep junk or use the bin.
- The player must be inside the house to sweep, and near the bin to dump.
- Each piece has to be claimed before it is swept. Two players cannot take the same piece, and the
  progress time has to really pass.
- Requests are rate limited per player (`Junk.Cooldown`, `Bin.Cooldown`).
- Bags are checked for the right property tag before they are taken.
- Bin positions are validated: outside the property, close enough to it, and within sensible world limits.
- Owners cannot empty their own bin, and each bin can only be collected once per cooldown.

---

## 8. Troubleshooting

| Problem | Check |
|---|---|
| No junk appears | `Cleaning.Enabled` and `Junk.Enabled` are `true`; the property is an owned **house** (not an apartment); someone has been inside for `Junk.IntervalMinutes`. Lower the interval to test. |
| "Garbage Bin Location" or the Garbage Bin section is missing | `Cleaning.Enabled` is `false`; or for the tablet, `Bin.OwnerCanPlace` is `false` or the player is not the owner. |
| Can't sweep up | The player needs a key (owner or entry permission). Check `ox_target` is running. |
| No bag received | The player's inventory is full, or the `trash_bag` item is missing from `ox_inventory`. |
| "Dump trash bags" doesn't show | The player must carry bags swept up in **that** house. Bags from other houses don't count. |
| "These trash bags are not from this property." | The bags are from a different house, or untagged bags from before the update. |
| Junk floats or sits in walls | Pieces sit on a ring around the entry point. Lower `Junk.MaxRadius`, or raise `MinRadius`, for small or oddly shaped interiors. |
| The bin never gets emptied | Garbage-job hooks are written for `ghm-garbagejob`. See [Emptying the bin](#emptying-the-bin-garbage-job). |
| Changes to settings do nothing | Restart the resource. |
