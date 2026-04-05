# Problem 5 - Data Assistant Pipeline Design

## Task

Design a pipeline that takes raw per-battle, per-user, per-vehicle data from a centralized DWH and delivers aggregated vehicle usage statistics (crew skills, battle boosters, equipment, etc.) to the **Data Assistant** feature in the WoT HEAT game client.

Requirements: scalability, maintainability, efficiency.

---

## The Core Problem

The DWH is optimized for **throughput** - scanning billions of rows to produce analytical results. The game client needs **low latency** - a player opening their garage cannot wait seconds for a DWH query to complete.

The pipeline bridges this gap by **pre-computing aggregations** and storing the results in a fast serving layer. The DWH is never queried directly by the client.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          DATA SOURCES                               │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  Centralized DWH  (Snowflake / BigQuery / Redshift)          │  │
│   │  - battles, battle_participants, battle_player_stats         │  │
│   │  - vehicle inventory, crew skills, equipment, boosters       │  │
│   └──────────────────────────────┬───────────────────────────────┘  │
└──────────────────────────────────┼──────────────────────────────────┘
                                   │ batch reads (incremental)
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       AGGREGATION LAYER                             │
│                                                                     │
│   ┌──────────────┐    ┌──────────────────────────────────────────┐  │
│   │  Orchestrator│    │  Aggregation Jobs  (SQL / dbt / Spark)   │  │
│   │  (Airflow)   │───►│  - read new battles since watermark      │  │
│   │              │    │  - compute per-player per-vehicle stats  │  │
│   │  schedule:   │    │  - upsert into aggregated store          │  │
│   │  every 5 min │    │  - advance watermark                     │  │
│   └──────────────┘    └──────────────────────┬───────────────────┘  │
└──────────────────────────────────────────────┼──────────────────────┘
                                               │ upserts
                                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        SERVING LAYER                                │
│                                                                     │
│   ┌──────────────────────────┐    ┌──────────────────────────────┐  │
│   │  Aggregated Store        │    │  Cache  (Redis)              │  │
│   │  (PostgreSQL / MongoDB)  │◄───│  TTL: 5 minutes              │  │
│   │  keyed by player_id      │    │  keyed by player_id          │  │
│   └──────────────────────────┘    └──────────────────┬───────────┘  │
│                                                      │              │
│                    ┌─────────────────────────────────┘              │
│                    ▼                                                 │
│   ┌──────────────────────────┐                                      │
│   │  API Service             │                                      │
│   │  (REST / gRPC)           │                                      │
│   │  GET /players/{id}/stats │                                      │
│   └──────────────┬───────────┘                                      │
└──────────────────┼──────────────────────────────────────────────────┘
                   │ HTTP / gRPC
                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        GAME CLIENT                                  │
│   Data Assistant - vehicle stats, crew skills, equipment, boosters  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Stage 1 - DWH (Source of Truth)

The DWH holds all raw data: the battle schema from Problem 1 plus additional tables for:

- **Vehicle inventory** - which vehicles a player has in their garage
- **Crew skill assignments** - which skills are assigned per crew member per vehicle
- **Equipment loadouts** - which equipment modules are mounted on each vehicle
- **Battle booster usage** - which boosters were activated per battle

This data is append-only and immutable once written. The pipeline reads from it but never modifies it.

---

## Stage 2 - Aggregation Layer

### Orchestrator (Apache Airflow)

Airflow triggers aggregation jobs on a schedule (every 5–15 minutes depending on required freshness). It manages retries, dependency tracking, and alerting.

Each DAG run:
1. Reads the **watermark** - the timestamp of the last successfully processed battle
2. Queries the DWH for all battles completed after the watermark
3. Runs the aggregation job
4. On success, advances the watermark to the latest processed battle timestamp

### Aggregation Jobs

The jobs compute per-player per-vehicle statistics from new battles only (**incremental processing**). They upsert results into the aggregated store using `INSERT ... ON CONFLICT DO UPDATE`.

Example metrics computed per player per vehicle:

| Metric | Description |
|---|---|
| `battles_played` | Total battles in this vehicle |
| `wins / losses / draws` | Outcome counts |
| `avg_damage_dealt` | Rolling average damage |
| `avg_kills` | Rolling average kills |
| `crew_skill_usage` | JSON map of skill → activation count |
| `equipment_usage` | JSON map of equipment → battles equipped |
| `booster_usage` | JSON map of booster type → usage count |
| `last_battle_at` | Timestamp of most recent battle |
| `updated_at` | Last time this record was refreshed |

### Why incremental and not full recompute?

At billions of battles, reprocessing all history on every job run would take hours. The incremental watermark pattern ensures each job run only touches the **delta** - the new battles since the last run. A player finishing a battle sees updated stats within one job cycle (minutes), with jobs completing in seconds.

---

## Stage 3 - Aggregated Store

A fast, read-optimized database that stores pre-computed stats per player.

**Schema (conceptual):**

```sql
CREATE TABLE player_vehicle_stats (
    player_id       UUID         NOT NULL,
    vehicle_id      INT          NOT NULL,
    battles_played  INT          NOT NULL DEFAULT 0,
    wins            INT          NOT NULL DEFAULT 0,
    losses          INT          NOT NULL DEFAULT 0,
    draws           INT          NOT NULL DEFAULT 0,
    total_damage    BIGINT       NOT NULL DEFAULT 0,
    total_kills     INT          NOT NULL DEFAULT 0,
    crew_skills     JSONB,        -- { "skill_name": usage_count, ... }
    equipment       JSONB,        -- { "equipment_name": battles_equipped, ... }
    boosters        JSONB,        -- { "booster_type": usage_count, ... }
    last_battle_at  TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, vehicle_id)
);

CREATE INDEX idx_pvs_player_id ON player_vehicle_stats(player_id);
```

`JSONB` columns are used for crew skills, equipment, and boosters because their schemas evolve independently (new skills and equipment are introduced with game updates). Storing them as structured JSON avoids schema migrations every time a new item is added.

---

## Stage 4 - Cache Layer (Redis)

Redis sits between the API and the aggregated store. When a player opens their garage:

1. API checks Redis for key `stats:{player_id}`
2. **Cache hit** (most common): return cached JSON - sub-millisecond latency
3. **Cache miss**: query aggregated store, serialize result, write to Redis with TTL of 5 minutes, return result

**TTL of 5 minutes** matches the aggregation job frequency. There is no value in serving data fresher than the pipeline can produce it.

**Cache invalidation**: the aggregation job explicitly invalidates `stats:{player_id}` for every player whose records were updated in that run. This ensures that after a job completes, the next client request always fetches fresh data rather than waiting for TTL expiry.

---

## Stage 5 - API Service

A lightweight stateless service exposing a single endpoint per consumer need:

```
GET /v1/players/{player_id}/garage-stats
```

Returns the full aggregated stats payload for all vehicles in the player's garage. The game client calls this once when the player opens their garage.

**Response structure (example):**

```json
{
  "player_id": "uuid",
  "generated_at": "2024-03-10T14:22:00Z",
  "vehicles": [
    {
      "vehicle_id": 1001,
      "name": "T-72B3",
      "battles_played": 412,
      "win_rate": 0.54,
      "avg_damage": 1340.5,
      "avg_kills": 1.8,
      "crew_skills": { "repair": 412, "camouflage": 390 },
      "equipment": { "enhanced_suspension": 412, "coated_optics": 289 },
      "boosters": { "x2_xp": 45, "crew_xp": 12 }
    }
  ]
}
```

The API is **stateless** and horizontally scalable - any number of instances can run behind a load balancer with no coordination.

---

## Scalability

| Concern | Solution |
|---|---|
| More players / battles | Incremental jobs process only the delta; aggregated store scales horizontally (sharding by `player_id`) |
| Traffic spikes (e.g. new patch, tournament) | Redis absorbs read spikes; API instances scale horizontally behind load balancer |
| DWH query cost | Incremental watermark keeps each job scan small; jobs run on DWH compute separate from game server infra |
| Very active players (thousands of battles) | Rolling aggregates (store running totals + counts, compute averages on read) avoid rescanning history |

---

## Maintainability

| Concern | Solution |
|---|---|
| New stat types | Add column/key to aggregated store + update aggregation SQL; no client-breaking change if using JSONB for flexible fields |
| New game items (equipment, skills) | JSONB schema absorbs new keys automatically with no migration |
| Pipeline failures | Airflow retries failed runs; watermark only advances on success, so no data is skipped |
| Observability | Each pipeline stage emits metrics: DWH query duration, rows processed, upsert count, cache hit/miss rate, API p99 latency |
| Schema versioning | API responses include a `schema_version` field; clients can handle backward compatibility gracefully |

---

## Efficiency

| Concern | Solution |
|---|---|
| DWH compute cost | Incremental jobs minimize rows scanned per run |
| Aggregated store write amplification | `INSERT ... ON CONFLICT DO UPDATE` (upsert) in one statement per player-vehicle pair |
| API read latency | Redis cache serves most requests in < 1ms; aggregated store query is a single primary-key lookup |
| Network payload | API returns only vehicles currently in the player's garage, not all historical vehicles |
| Cache memory | TTL + LRU eviction keeps only recently active players in cache; inactive players are evicted naturally |

---

## Data Flow Summary

```
New battle ends
      │
      ▼
DWH receives raw battle record  (battle_participants, battle_player_stats, ...)
      │
      ▼  (within ~5 minutes)
Airflow triggers aggregation job
      │
      ├── reads new battles since watermark from DWH
      ├── computes updated per-player per-vehicle stats
      ├── upserts into aggregated store
      ├── invalidates Redis keys for affected players
      └── advances watermark
      │
      ▼  (player opens garage)
Game client → API Service
      │
      ├── cache hit  → Redis returns stats  (<1ms)
      └── cache miss → aggregated store lookup → cache write → return stats  (<10ms)
```
