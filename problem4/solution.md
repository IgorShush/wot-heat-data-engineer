# Problem 4 — Per-Player Per-Day Metrics

## Task

Using the schema from Problem 1, write a single query that returns **one row per player per day** containing:

1. `damage_dealt_7th_win` — damage dealt in the player's 7th winning battle that day
2. `kills_3rd_loss` — kills made in the player's 3rd losing battle that day
3. `first_draw_started_at` — date and time of the player's 1st draw that day

All three values are `NULL` when the player did not reach that threshold on a given day.

---

## Technique: ROW_NUMBER + Conditional Aggregation

Each metric requires picking a **specific-ranked battle of a specific outcome type** within a player-day window. The approach combines two patterns:

1. **`ROW_NUMBER()`** — ranks battles independently per result type (wins, losses, draws) within each player-day group.
2. **Conditional aggregation** — `MAX(CASE WHEN ... THEN value END)` extracts the one matching value per metric without needing a separate subquery or self-join for each.

---

## Query Structure

```
battle_results  →  classify each battle as win / loss / draw, join stats
     ↓
ranked          →  number each battle within (player, date, result)
     ↓
Final SELECT    →  GROUP BY (player, date), conditional aggregation to pick
                   7th win / 3rd loss / 1st draw
```

---

## CTE Breakdown

### `battle_results`

```sql
CASE
    WHEN b.winning_team = bp.team_number THEN 'win'
    WHEN b.winning_team IS NULL           THEN 'draw'
    ELSE                                       'loss'
END AS result
```

Determines the battle outcome from the **player's perspective** — the same battle is a win for one team and a loss for the other.

```sql
(b.started_at AT TIME ZONE 'UTC')::DATE AS battle_date
```

Converts the UTC timestamp to a calendar date explicitly in UTC. Using `::DATE` alone would apply the database session's timezone, which can silently shift the day boundary for players and servers in different regions.

---

### `ranked`

```sql
ROW_NUMBER() OVER (
    PARTITION BY player_id, battle_date, result
    ORDER BY started_at, battle_id
) AS rn
```

This is the key step. By partitioning on `(player_id, battle_date, result)`, the counter resets independently for each result type within each player-day:

| Battle | Result | rn |
|--------|--------|----|
| 09:14 | win  | 1 |
| 10:02 | loss | 1 |
| 10:45 | win  | 2 |
| 11:30 | win  | 3 |
| 12:18 | draw | 1 |
| 13:05 | loss | 2 |
| 14:22 | win  | 4 |
| ...   | ...  | ...|
| 21:07 | win  | 7 | ← damage_dealt captured here |

`battle_id` in `ORDER BY` ensures deterministic ordering when two battles share the exact same `started_at` timestamp.

---

### Final SELECT — Conditional Aggregation

```sql
MAX(CASE WHEN result = 'win'  AND rn = 7 THEN damage_dealt END)  AS damage_dealt_7th_win,
MAX(CASE WHEN result = 'loss' AND rn = 3 THEN kills        END)  AS kills_3rd_loss,
MAX(CASE WHEN result = 'draw' AND rn = 1 THEN started_at   END)  AS first_draw_started_at
```

After grouping by `(player_id, battle_date)`, each `CASE` expression matches **at most one row** in the group — the row where `result` and `rn` both match. `MAX()` extracts that single value; if no row matches, the result is `NULL`.

This is more efficient than three separate subqueries or lateral joins because the data is scanned only once.

---

## Worked Example

Player **Igor** on **2024-03-10**:

| # | Time | Result | damage_dealt | kills | rn |
|---|------|--------|-------------|-------|----|
| 1 | 09:14 | win  | 1 200 | 2 | win#1 |
| 2 | 10:02 | loss | 800   | 0 | loss#1 |
| 3 | 10:45 | win  | 950   | 1 | win#2 |
| 4 | 11:30 | win  | 1 750 | 3 | win#3 |
| 5 | 12:18 | draw | 600   | 0 | draw#1 |
| 6 | 13:05 | loss | 400   | 1 | loss#2 |
| 7 | 14:22 | win  | 2 100 | 4 | win#4 |
| 8 | 15:11 | loss | 300   | 0 | loss#3 |
| ...| ... | ... | ... | ... | ... |
| 14 | 21:07 | win | **1 340** | 2 | **win#7** |

Output row for Igor on 2024-03-10:

| player | battle_date | damage_dealt_7th_win | kills_3rd_loss | first_draw_started_at |
|--------|-------------|----------------------|----------------|-----------------------|
| Igor   | 2024-03-10  | **1 340**            | **0**          | **2024-03-10 12:18**  |

- `damage_dealt_7th_win = 1 340` — from win#7 at 21:07
- `kills_3rd_loss = 0` — from loss#3 at 15:11
- `first_draw_started_at = 2024-03-10 12:18` — from draw#1 at 12:18

---

## NULL Semantics

| Scenario | Value |
|---|---|
| Player had fewer than 7 wins that day | `damage_dealt_7th_win = NULL` |
| Player had fewer than 3 losses that day | `kills_3rd_loss = NULL` |
| Player had no draws that day | `first_draw_started_at = NULL` |
| Player had no battles that day | Row does not appear at all |

---

## Output Columns

| Column | Type | Description |
|---|---|---|
| `player_id` | UUID | Player identifier |
| `username` | VARCHAR | Player display name |
| `battle_date` | DATE | Calendar date in UTC |
| `damage_dealt_7th_win` | INT | Damage dealt in the 7th win of the day; NULL if < 7 wins |
| `kills_3rd_loss` | INT | Kills in the 3rd loss of the day; NULL if < 3 losses |
| `first_draw_started_at` | TIMESTAMPTZ | Timestamp of first draw of the day; NULL if no draw |
