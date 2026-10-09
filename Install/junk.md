# Junk, Trash Bags & Garbage Bins

Houses get messy. While someone is home, junk piles up. People with a key sweep it into trash bags,
carry the bags outside and dump them in the house's garbage bin. What happens to them after that is up to your
server: by default the bags just disappear. If you turn on `Bin.KeepContents`, they stay in the bin and other
resources can use them through the exports (for example to build a garbage job).

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
| `true` | `false` | No junk. Bins can still be placed, but with no junk there are no bags to put in them. |

Notes:
- Restart the resource after changing a setting.
- Turning the system off does not delete anything. Junk and bin contents stay saved on the property and
  come back if you turn it on again.
- Bins never fill by themselves. Only bags that players bring from cleaning their house go in.
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
- The **Dump trash bags** target on the bin takes the player's bags for that house (`Bin.DumpMs`). The target
  only shows if the player is carrying bags from that house.
- What happens to the bags depends on `Bin.KeepContents`, see below.
- A bin only ever holds bags that players put in it. It does not fill by itself.

### What happens to the bags

| `Bin.KeepContents` | What happens |
|---|---|
| `false` (default) | The bags are thrown away. The bin never fills, so it can never be full. There is no "Check bin" target and no pile of bags. |
| `true` | The bags stay in the bin. It holds `Bin.Capacity` bags (default 12); when it is full it refuses more and the player keeps the rest. Bags pile up beside the bin as it fills (1 at half full, 3 at three quarters, 4 when full), and a **Check bin** target shows the fill level and when it was last emptied. |

With `KeepContents = true` nothing empties the bin on its own. Another resource has to do that, see
[Building on the bin exports](#7-building-on-the-bin-exports).
### Bags only count for their own house

Each `trash_bag` is created with the property ID attached, and the inventory shows "Junk from <house name>".
The bin only accepts bags tagged for its own property. Bags from another house, or from any other source
(another script, an admin command, a shop), are ignored. This means a bin can only be filled by cleaning
the house it belongs to. Bags of the same house stack together.

If `trash_bag` items existed before you installed this, they have no tag and will not be accepted by any bin.

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

Removing a bin also clears what is in it and its last-emptied time, so a moved bin starts fresh.

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
| `Bin.KeepContents` | `false` | `false`: bags put in the bin disappear and the bin never fills. `true`: the bags stay in the bin so other resources can use them. |
| `Bin.Capacity` | `12` | Only used when `KeepContents` is `true`. How many bags the bin holds before it refuses more. |
| `Bin.DumpMs` | `1500` | Time to dump your bags. |
| `Bin.Cooldown` | `750` | Minimum ms between bin requests per player. |
| `Bin.Placement.MaxDistance` | `12.0` | How far the placement ray reaches. |
| `Bin.Placement.RotateStep` | `5.0` | Degrees per scroll tick. |
| `Bin.Placement.WaitTimeout` | `300000` | Owner placement: ms to walk outside before it cancels. |

---

## 6. Exports and events

**Server exports**

| Export | Returns |
|---|---|
| `GetPropertyBins(minFill?)` | Every bin in service as `{ propertyId, label, coords, fill, capacity, emptiedAt }`. Pass `minFill` to only get bins holding at least that many bags. Empty when the system is off. `fill` is always `0` unless `Bin.KeepContents` is on. |
| `GetPropertyBin(propertyId)` | The same table for one property, or `nil` if it has no bin in service. |
| `SetBinFill(propertyId, fill)` | Sets how many bags are in a bin (clamped to the capacity). Returns `boolean`. Needs `Bin.KeepContents`. |
| `EmptyBin(propertyId, src?)` | Empties a bin, records the time, tells the owner and fires `binEmptied`. Returns `{ ok, bags? }`. Needs `Bin.KeepContents`. |
| `GetPropertyJunk(propertyId)` | Number of junk pieces in a house, or `nil` for apartments. |
| `GetPropertyOccupants(propertyId)` | Player IDs currently inside a property. |

`emptiedAt` is a Unix time in seconds, or `0` if the bin has never been emptied.

**Client exports**

| Export | Returns |
|---|---|
| `GetBinModel()` | The bin prop model name, for targeting. |
| `GetNearestBinPropertyId(coords, maxDistance?)` | Property ID of the closest spawned bin, or `nil`. |

**Server events**

| Event | Arguments | When |
|---|---|---|
| `LNS_Housing:server:binFillChanged` | `propertyId, fill, capacity` | A bin's fill level changed (bags dumped, `SetBinFill`, emptied). |
| `LNS_Housing:server:binEmptied` | `propertyId, src, bags` | `EmptyBin` was called. `src` is whatever you passed, or `nil`. |

---

## 7. Building on the bin exports

These need `Bin.KeepContents = true`, otherwise the bags are thrown away and there is nothing in the bin to work
with. The exports trust the resource that calls them. `EmptyBin` and `SetBinFill` do not check who is asking,
how close they are or whether they are on a job, so **do those checks in your own resource** before calling them.

A simple pickup job could look like this:

```lua
-- server side of your own resource
local function startRoute(src)
    -- bins that are at least half full
    local bins = exports.LNS_Housing:GetPropertyBins(6)
    -- send the player to bins[i].coords ...
end

RegisterNetEvent('myjob:server:emptyBin', function(propertyId)
    local src = source
    if not isOnDuty(src) then return end                       -- your job check
    local bin = exports.LNS_Housing:GetPropertyBin(propertyId)
    if not bin or bin.fill < 6 then return end                 -- still worth emptying?
    if not isNear(src, bin.coords, 4.0) then return end        -- your distance check
    if os.time() - bin.emptiedAt < 3600 then return end        -- your own cooldown

    local result = exports.LNS_Housing:EmptyBin(propertyId, src)
    if result.ok then
        payPlayer(src, result.bags * 25)                       -- your own reward
    end
end)
```

Other ideas that only need these exports: let the owner request a pickup for a tip, charge a fee or spawn pests
when a bin stays full, or let players pick through a full bin.

On the client, use `GetBinModel()` to add an `ox_target` option to every bin, and
`GetNearestBinPropertyId(coords)` to find which property the bin you are targeting belongs to.

---

## 8. Safety checks

All of these happen on the server, so a modified client cannot get around them:

- Only the owner or a keyholder can sweep junk or use the bin.
- The player must be inside the house to sweep, and near the bin to dump.
- Each piece has to be claimed before it is swept. Two players cannot take the same piece, and the
  progress time has to really pass.
- Requests are rate limited per player (`Junk.Cooldown`, `Bin.Cooldown`).
- Bags are checked for the right property tag before they are taken.
- Bin positions are validated: outside the property, close enough to it, and within sensible world limits.

---

## 9. Troubleshooting

| Problem | Check |
|---|---|
| No junk appears | `Cleaning.Enabled` and `Junk.Enabled` are `true`; the property is an owned **house** (not an apartment); someone has been inside for `Junk.IntervalMinutes`. Lower the interval to test. |
| "Garbage Bin Location" or the Garbage Bin section is missing | `Cleaning.Enabled` is `false`; or for the tablet, `Bin.OwnerCanPlace` is `false` or the player is not the owner. |
| Can't sweep up | The player needs a key (owner or entry permission). Check `ox_target` is running. |
| No bag received | The player's inventory is full, or the `trash_bag` item is missing from `ox_inventory`. |
| "Dump trash bags" doesn't show | The player must carry bags swept up in **that** house. Bags from other houses don't count. |
| "These trash bags are not from this property." | The bags are from a different house, or untagged bags from before the update. |
| Junk floats or sits in walls | Pieces sit on a ring around the entry point. Lower `Junk.MaxRadius`, or raise `MinRadius`, for small or oddly shaped interiors. |
| The bin never gets emptied | Nothing empties it on its own. With `Bin.KeepContents = true`, use `EmptyBin` from your own job or script (see [Building on the bin exports](#7-building-on-the-bin-exports)). |
| The bin never fills or shows a pile of bags | `Bin.KeepContents` is `false` (the default), so dumped bags are thrown away. |
| Changes to settings do nothing | Restart the resource. |
