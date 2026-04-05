# WoT HEAT Data Engineer Test Task

Solutions to the Data Engineer test task for the **WoT HEAT Team** at Wargaming.

All schemas target **PostgreSQL** and are designed to handle billions of rows of game data.

---

## Problems

| # | Title |
|---|---|
| [Problem 1](./problem1/schema.md) | Battle schema design |
| [Problem 2](./problem2/schema.md) | Graphics settings schema |
| [Problem 3](./problem3/solution.md) | Longest consecutive win streak (SQL) |
| [Problem 4](./problem4/solution.md) | Per-player per-day metrics (SQL) |
| [Problem 5](./problem5/solution.md) | Data pipeline design (Data Assistant feature) |

---

## Problem 1 - Battle Schema

Designs a normalized PostgreSQL schema to store comprehensive battle data in WoT HEAT.

- **[schema.md](./problem1/schema.md)** - full explanation of every table and design decision
- **[schema.sql](./problem1/schema.sql)** - ready-to-run PostgreSQL DDL

### Key design decisions

- **UUID primary keys** on `battles` and `players` - multiple game servers generate records in parallel; UUIDs avoid central sequence bottlenecks and collision risks.
- **Lookup tables** for `battle_types`, `maps`, `death_reasons` - avoids repeating strings across billions of rows.
- **Separated fact tables** - `battle_participants` (identity/role), `battle_player_stats` (combat metrics), `battle_player_economy` (currency flows) - each table has a single responsibility and can evolve, compress, and scale independently.
- **`winning_team = NULL` means draw** - semantically correct, avoids a redundant boolean column.

---

## Problem 2 - Graphics Settings Schema

Designs an efficient schema to store the graphics settings each player used per battle.

- **[schema.md](./problem2/schema.md)** - full explanation of every table and design decision
- **[schema.sql](./problem2/schema.sql)** - ready-to-run PostgreSQL DDL

### Key design decisions

- **Snapshot + deduplication pattern** - each unique combination of settings is stored once in `graphics_profiles`; battles reference it via a tiny two-column link table `battle_graphics_settings`. Players who never change settings share one profile row across all their battles.
- **`settings_hash`** - an MD5 digest of all setting values enables fast, lock-free deduplication using `ON CONFLICT DO NOTHING`.
- **Shared quality level lookup** - all six graphics dropdowns (General, Objects, Terrain, etc.) reference the same `graphics_quality_levels` table instead of six identical lookups.
- **`BIGSERIAL` for `profile_id`** - profiles are created centrally (not on distributed game servers), so a sequential integer is safe, cheaper to store, and faster to join than a UUID.

## Problem 3 - Longest Consecutive Win Streak

Finds the longest unbroken series of wins for every player who participated in any battle.

- **[solution.md](./problem3/solution.md)** - full explanation of the technique and query structure
- **[query.sql](./problem3/query.sql)** - ready-to-run PostgreSQL query

### Key design decisions

- **Gaps and Islands technique** - two `ROW_NUMBER()` window functions per player (one over all battles, one over wins only); their difference is constant within a consecutive win streak, identifying each "island" without recursion.
- **Draws break streaks** - only `winning_team = bp.team_number` counts as a win; draws and losses both map to `FALSE` and interrupt a streak equally.
- **Zero-win players included** - a `LEFT JOIN` + `COALESCE(..., 0)` ensures every participant appears in the output, even those who never won a battle.
- **Tiebreaker on `battle_id`** - `ORDER BY started_at, battle_id` guarantees a deterministic ordering when two battles share the same timestamp.

## Problem 4 - Per-Player Per-Day Metrics

Retrieves three specific-ranked battle metrics per player per day in a single query.

- **[solution.md](./problem4/solution.md)** - full explanation with a worked example
- **[query.sql](./problem4/query.sql)** - ready-to-run PostgreSQL query

### Key design decisions

- **`ROW_NUMBER()` partitioned by `(player_id, battle_date, result)`** - gives an independent rank counter per result type per player per day, cleanly separating win#1...N, loss#1...N, draw#1...N.
- **Conditional aggregation** - `MAX(CASE WHEN result = 'win' AND rn = 7 THEN damage_dealt END)` extracts the single matching value per metric in one pass over the data, avoiding three separate subqueries.
- **Explicit UTC date conversion** - `(started_at AT TIME ZONE 'UTC')::DATE` prevents silent day-boundary shifts from database session timezone settings.
- **`NULL` semantics** - thresholds not reached (e.g. fewer than 7 wins) produce `NULL`, naturally distinguishing "not enough battles" from "zero damage".

## Problem 5 - Data Assistant Pipeline

Designs an end-to-end pipeline from raw DWH data to aggregated vehicle stats in the game client.

- **[solution.md](./problem5/solution.md)** - full architecture design with diagrams, stage-by-stage breakdown, and scalability / maintainability / efficiency analysis

### Architecture stages

1. **DWH** - centralized source of truth; raw battle and vehicle data; never queried directly by the client
2. **Aggregation layer** - Airflow-orchestrated incremental jobs; watermark pattern ensures only new battles are processed each run; upserts pre-computed stats into the aggregated store
3. **Aggregated store** - PostgreSQL (or MongoDB) keyed by `player_id`; `JSONB` columns for crew skills, equipment, and boosters to absorb schema evolution without migrations
4. **Cache layer** - Redis with 5-minute TTL; explicit invalidation by the aggregation job on write; absorbs read spikes transparently
5. **API service** - stateless, horizontally scalable REST/gRPC service; single endpoint per player; returns only garage-active vehicles

### Key design decisions

- **Incremental watermark** - jobs process only the delta since the last run; keeps DWH compute cost low and job duration in seconds regardless of total history size
- **Pre-aggregation** - DWH is optimized for throughput, not latency; pre-computing results decouples write scale from read latency
- **JSONB for evolving schemas** - crew skills, equipment, and boosters change with every game patch; JSONB absorbs new keys without ALTER TABLE
- **Cache invalidation on write** - aggregation job explicitly evicts Redis keys for updated players, so clients always see fresh data after the next job run rather than waiting for TTL expiry
