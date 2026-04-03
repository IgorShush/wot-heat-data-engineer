# WoT HEAT Data Engineer Test Task

Solutions to the Data Engineer test task for the **WoT HEAT Team** at Wargaming.

All schemas target **PostgreSQL** and are designed to handle billions of rows of game data.

---

## Problems

| # | Title | Status |
|---|---|---|
| [Problem 1](./problem1/schema.md) | Battle schema design | ✅ Done |
| [Problem 2](./problem2/schema.md) | Graphics settings schema | ✅ Done |
| [Problem 3](./problem3/solution.md) | Longest consecutive win streak (SQL) | ✅ Done |
| [Problem 4](./problem4/solution.md) | Per-player per-day metrics (SQL) | ✅ Done |
| Problem 5 | Data pipeline design (Data Assistant feature) | 🔜 Coming |

---

## Problem 1 — Battle Schema

Designs a normalized PostgreSQL schema to store comprehensive battle data in WoT HEAT.

- **[schema.md](./problem1/schema.md)** — full explanation of every table and design decision
- **[schema.sql](./problem1/schema.sql)** — ready-to-run PostgreSQL DDL

### Key design decisions

- **UUID primary keys** on `battles` and `players` — multiple game servers generate records in parallel; UUIDs avoid central sequence bottlenecks and collision risks.
- **Lookup tables** for `battle_types`, `maps`, `death_reasons` — avoids repeating strings across billions of rows.
- **Separated fact tables** — `battle_participants` (identity/role), `battle_player_stats` (combat metrics), `battle_player_economy` (currency flows) — each table has a single responsibility and can evolve, compress, and scale independently.
- **`winning_team = NULL` means draw** — semantically correct, avoids a redundant boolean column.

---

## Problem 2 — Graphics Settings Schema

Designs an efficient schema to store the graphics settings each player used per battle.

- **[schema.md](./problem2/schema.md)** — full explanation of every table and design decision
- **[schema.sql](./problem2/schema.sql)** — ready-to-run PostgreSQL DDL

### Key design decisions

- **Snapshot + deduplication pattern** — each unique combination of settings is stored once in `graphics_profiles`; battles reference it via a tiny two-column link table `battle_graphics_settings`. Players who never change settings share one profile row across all their battles.
- **`settings_hash`** — an MD5 digest of all setting values enables fast, lock-free deduplication using `ON CONFLICT DO NOTHING`.
- **Shared quality level lookup** — all six graphics dropdowns (General, Objects, Terrain, etc.) reference the same `graphics_quality_levels` table instead of six identical lookups.
- **`BIGSERIAL` for `profile_id`** — profiles are created centrally (not on distributed game servers), so a sequential integer is safe, cheaper to store, and faster to join than a UUID.

## Problem 3 — Longest Consecutive Win Streak

Finds the longest unbroken series of wins for every player who participated in any battle.

- **[solution.md](./problem3/solution.md)** — full explanation of the technique and query structure
- **[query.sql](./problem3/query.sql)** — ready-to-run PostgreSQL query

### Key design decisions

- **Gaps and Islands technique** — two `ROW_NUMBER()` window functions per player (one over all battles, one over wins only); their difference is constant within a consecutive win streak, identifying each "island" without recursion.
- **Draws break streaks** — only `winning_team = bp.team_number` counts as a win; draws and losses both map to `FALSE` and interrupt a streak equally.
- **Zero-win players included** — a `LEFT JOIN` + `COALESCE(..., 0)` ensures every participant appears in the output, even those who never won a battle.
- **Tiebreaker on `battle_id`** — `ORDER BY started_at, battle_id` guarantees a deterministic ordering when two battles share the same timestamp.

## Problem 4 — Per-Player Per-Day Metrics

Retrieves three specific-ranked battle metrics per player per day in a single query.

- **[solution.md](./problem4/solution.md)** — full explanation with a worked example
- **[query.sql](./problem4/query.sql)** — ready-to-run PostgreSQL query

### Key design decisions

- **`ROW_NUMBER()` partitioned by `(player_id, battle_date, result)`** — gives an independent rank counter per result type per player per day, cleanly separating win#1...N, loss#1...N, draw#1...N.
- **Conditional aggregation** — `MAX(CASE WHEN result = 'win' AND rn = 7 THEN damage_dealt END)` extracts the single matching value per metric in one pass over the data, avoiding three separate subqueries.
- **Explicit UTC date conversion** — `(started_at AT TIME ZONE 'UTC')::DATE` prevents silent day-boundary shifts from database session timezone settings.
- **`NULL` semantics** — thresholds not reached (e.g. fewer than 7 wins) produce `NULL`, naturally distinguishing "not enough battles" from "zero damage".
