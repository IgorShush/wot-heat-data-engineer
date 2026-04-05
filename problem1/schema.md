# Problem 1 - Battle Schema Design

## Overview

The goal is to design a schema that stores comprehensive details about every battle in **WoT HEAT**, at a scale of **billions of rows**. The schema targets **PostgreSQL** and follows a normalized, lookup-table-driven approach optimized for both write throughput and analytical queries.

---

## Design Principles

1. **Narrow fact tables** - each table has a focused responsibility. Combat stats, economy, and participant identity are kept in separate tables. This makes it easier to add columns without touching unrelated data, and allows columnar storage engines to compress data more effectively.

2. **Lookup tables for enumerations** - types like `battle_types`, `maps`, and `death_reasons` are stored once and referenced by integer ID. This avoids repeating string values across billions of rows.

3. **UUID primary keys** - `battles` and `players` use `UUID` rather than `BIGSERIAL`. Because multiple game servers generate battle records independently and in parallel, a centralized auto-increment sequence would become a bottleneck and a single point of failure. UUIDs are generated locally by each server with no coordination required and no risk of collision.

4. **Indexes on foreign keys and time columns** - `started_at`, `battle_type_id`, `map_id`, `player_id` are all indexed because they are the most common filter and join columns in analytical queries.

---

## Entity Relationship

```
players ──────────────────────────────────────────────┐
                                                       │
battle_types ──┐                                       │
               ├──► battles ──► battle_participants ◄──┤
maps ──────────┘         │              │              │
                         │              ▼              │
                         │   battle_player_stats       │
                         │   battle_player_economy     │
                         │                             │
                         └── (server_id, winning_team) │
                                                       │
death_reasons ─────────────────────────────────────────┘
```

---

## Tables

### `players`
Central registry of all players.

| Column | Type | Notes |
|---|---|---|
| `player_id` | UUID PK | Generated with `gen_random_uuid()` |
| `username` | VARCHAR(64) | Unique, indexed |
| `created_at` | TIMESTAMPTZ | Account creation timestamp |

---

### `battle_types`
Lookup table for battle scenarios and rulesets (e.g. Standard, Ranked, Skirmish).

| Column | Type | Notes |
|---|---|---|
| `battle_type_id` | SERIAL PK | Small integer, fits in cache |
| `name` | VARCHAR(64) | Unique type name |
| `description` | TEXT | Optional human-readable explanation |

> Storing the type name as a FK integer instead of a repeated string saves significant space at billion-row scale.

---

### `maps`
Lookup table for maps and arenas.

| Column | Type | Notes |
|---|---|---|
| `map_id` | SERIAL PK | |
| `name` | VARCHAR(128) | Unique map name |
| `external_id` | VARCHAR(64) | ID used by the game engine |

---

### `death_reasons`
Lookup table for how a player's vehicle was destroyed or why they left early.

| Column | Type | Notes |
|---|---|---|
| `death_reason_id` | SERIAL PK | |
| `code` | VARCHAR(64) | Machine-readable code, e.g. `destroyed_by_player` |
| `description` | TEXT | Human-readable label |

Examples of codes: `destroyed_by_player`, `destroyed_by_fire`, `destroyed_by_environment`, `disconnected`, `left_voluntarily`.

---

### `battles`
The central fact record - one row per battle.

| Column | Type | Notes |
|---|---|---|
| `battle_id` | UUID PK | Generated independently per server, no central sequence |
| `started_at` | TIMESTAMPTZ | UTC timestamp, indexed |
| `duration_seconds` | INT | Must be > 0 |
| `battle_type_id` | INT FK | References `battle_types` |
| `map_id` | INT FK | References `maps` |
| `winning_team` | SMALLINT | `1` or `2`; `NULL` means draw |
| `server_id` | VARCHAR(64) | Game server that hosted the battle |

**Why `winning_team` and not `winning_team_id`?**
Teams are not persistent entities - they exist only within the scope of one battle. Storing `1` or `2` is sufficient and avoids an unnecessary join.

**Why `NULL` for draws?**
A `CHECK` constraint allows only `1`, `2`, or `NULL`. `NULL` is semantically accurate: there is no winner. This avoids adding a separate boolean `is_draw` column.

---

### `battle_participants`
One row per player per battle. Captures team membership, survival, death, and destroyer.

| Column | Type | Notes |
|---|---|---|
| `participant_id` | UUID PK | Surrogate key for this participation event |
| `battle_id` | UUID FK | References `battles` |
| `player_id` | UUID FK | References `players` |
| `team_number` | SMALLINT | `1` or `2` |
| `survived` | BOOLEAN | `TRUE` if player's vehicle was alive at battle end |
| `death_reason_id` | INT FK | References `death_reasons`; `NULL` if survived |
| `destroyed_by_player_id` | UUID FK | References `players`; `NULL` if survived or environment kill |
| `left_early` | BOOLEAN | `TRUE` if player exited before battle ended |

**Unique constraint on `(battle_id, player_id)`** - a player can only appear once per battle, enforced at the database level.

**`destroyed_by_player_id` vs. `destroyed_by_participant_id`?**
We reference `players.player_id` directly rather than `battle_participants.participant_id`. This keeps the FK simple and avoids a circular dependency during inserts (both participants must exist before the FK can be set, which complicates the write path).

---

### `battle_player_stats`
Combat performance metrics, one row per participant.

| Column | Type | Notes |
|---|---|---|
| `participant_id` | UUID PK/FK | 1-to-1 with `battle_participants` |
| `damage_dealt` | INT | Total HP of damage dealt |
| `damage_assisted` | INT | Damage assisted via spotting / tracking |
| `damage_received` | INT | Total HP of damage received |
| `kills` | INT | Vehicles destroyed |
| `vehicles_spotted` | INT | |
| `shots_fired` | INT | |
| `shots_hit` | INT | |
| `shots_penetrated` | INT | |
| `experience_earned` | INT | Total XP including premium bonuses |
| `base_xp` | INT | Base XP before multipliers |

**Why separated from `battle_participants`?**
Stat columns are purely numeric and grow independently of identity/role columns. Keeping them separate makes the identity table smaller (fits more rows in a buffer page) and allows the stats table to be optimized independently (e.g. compressed, partitioned, or moved to a columnar store).

---

### `battle_player_economy`
Virtual currency flows per player per battle.

| Column | Type | Notes |
|---|---|---|
| `participant_id` | UUID PK/FK | 1-to-1 with `battle_participants` |
| `credits_earned` | INT | Standard in-game currency earned |
| `credits_spent` | INT | Standard currency spent (e.g. repairs, ammo) |
| `gold_earned` | INT | Premium currency earned |
| `gold_spent` | INT | Premium currency spent |
| `bonds_earned` | INT | High-tier currency earned |
| `bonds_spent` | INT | High-tier currency spent |

**Why separated from stats?**
Currency schema evolves independently - new currency types can be added without touching combat stats. Queries about economy (e.g. revenue analysis) never need to join against damage columns, so keeping them apart also improves query performance.

---

## Answering the 9 Required Questions

| # | Question | Where to look |
|---|---|---|
| 1 | Date/time and duration of each battle | `battles.started_at`, `battles.duration_seconds` |
| 2 | Battle type | `battles.battle_type_id` → `battle_types.name` |
| 3 | Map/arena type | `battles.map_id` → `maps.name` |
| 4 | All players in a battle | `battle_participants` WHERE `battle_id = ?` |
| 5 | Which team each player was on; which team won | `battle_participants.team_number`, `battles.winning_team` |
| 6 | Player performance stats | `battle_player_stats` JOIN `battle_participants` |
| 7 | Virtual currencies earned/spent | `battle_player_economy` JOIN `battle_participants` |
| 8 | Reason of death / early leave | `battle_participants.death_reason_id` → `death_reasons.code`, `battle_participants.left_early` |
| 9 | Who destroyed this player's vehicle | `battle_participants.destroyed_by_player_id` → `players.username` |
