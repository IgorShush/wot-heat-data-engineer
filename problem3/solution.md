# Problem 3 - Longest Consecutive Win Streak per Player

## Task

Using the schema from Problem 1, write a SQL script to find the longest series of consecutive wins for every player who participated in any battle.

**Restriction:** recursive (hierarchical) queries are not allowed.

---

## Technique: Gaps and Islands

The standard non-recursive approach to detecting consecutive sequences in SQL is called **Gaps and Islands**. It relies entirely on window functions - no loops, no recursion, no self-joins.

### Core insight

Assign two row numbers to each battle per player, both ordered by time:

- `rn_all` - counts **every** battle, regardless of result
- `rn_partitioned` - counts battles **partitioned by result** (wins counted separately from losses/draws)

Within a consecutive run of wins, the difference `rn_all - rn_partitioned` is **constant**. The moment a loss or draw appears, it increments `rn_all` without incrementing the wins counter, permanently shifting the difference. Each shift marks the start of a new island.

### Worked example

| Battle | Result | rn_all | rn_partitioned | Difference | Island |
|--------|--------|--------|----------------|------------|--------|
| 1 | Win | 1 | 1 | **0** | A |
| 2 | Win | 2 | 2 | **0** | A |
| 3 | Loss | 3 | 1 | 2 | - |
| 4 | Win | 4 | 3 | **1** | B |
| 5 | Win | 5 | 4 | **1** | B |
| 6 | Win | 6 | 5 | **1** | B |
| 7 | Draw | 7 | 2 | 5 | - |
| 8 | Win | 8 | 6 | **2** | C |

After filtering to wins and grouping by `(player_id, difference)`:

| Island | Streak length |
|--------|---------------|
| A (diff=0) | 2 |
| B (diff=1) | **3** ← longest |
| C (diff=2) | 1 |

`MAX` → **3**. No recursion used at any point.

---

## Query Structure

The query is built as five CTEs, each with a single responsibility:

```
battle_results      → determine win/loss/draw per player per battle
      ↓
numbered            → assign rn_all and rn_partitioned
      ↓
streak_groups       → filter to wins, group by island key, count streak lengths
      ↓
max_streaks         → take MAX streak length per player
      ↓
all_participants    → ensure players with 0 wins are included
      ↓
Final SELECT        → join with players table, COALESCE 0 for no-win players
```

---

## CTE Breakdown

### `battle_results`

```sql
CASE
    WHEN b.winning_team = bp.team_number THEN TRUE
    ELSE FALSE
END AS is_win
```

A player wins when their `team_number` matches `battles.winning_team`. Both losses and draws map to `FALSE` - both break a win streak equally.

---

### `numbered`

```sql
ROW_NUMBER() OVER (
    PARTITION BY player_id
    ORDER BY started_at, battle_id
) AS rn_all,

ROW_NUMBER() OVER (
    PARTITION BY player_id, is_win
    ORDER BY started_at, battle_id
) AS rn_partitioned
```

`battle_id` is included in `ORDER BY` as a tiebreaker for battles that started at the exact same timestamp (edge case but possible on busy servers).

---

### `streak_groups`

```sql
SELECT
    player_id,
    rn_all - rn_partitioned AS island_key,
    COUNT(*) AS streak_length
FROM numbered
WHERE is_win = TRUE
GROUP BY player_id, rn_all - rn_partitioned
```

Filtering to `is_win = TRUE` before grouping means losses and draws are already excluded. Each `(player_id, island_key)` group is exactly one unbroken win streak.

---

### `max_streaks`

```sql
SELECT player_id, MAX(streak_length) AS longest_win_streak
FROM streak_groups
GROUP BY player_id
```

Simple aggregation. Players with no wins at all produce no rows here.

---

### `all_participants` + Final SELECT

```sql
COALESCE(ms.longest_win_streak, 0) AS longest_win_streak
```

A `LEFT JOIN` from all participants to `max_streaks` ensures players with zero wins appear in the output with a streak of `0` rather than being silently omitted.

---

## Why Not Recursion?

A recursive CTE would walk battle-by-battle per player, carrying a running streak counter. While logically straightforward, it has two problems at WoT HEAT's scale:

1. **Performance** - recursive CTEs typically cannot be parallelised and process rows one at a time. Window functions are set-based and execute in a single parallel pass.
2. **Engine support** - the problem explicitly states that recursive queries have limited support across different database engines. The Gaps and Islands approach runs on any engine that supports `ROW_NUMBER()` (PostgreSQL, MySQL 8+, SQL Server, BigQuery, Snowflake, Redshift - all do).

---

## Output

| Column | Description |
|---|---|
| `player_id` | UUID of the player |
| `username` | Player's display name |
| `longest_win_streak` | Length of their longest consecutive win streak (0 if never won) |

Results are ordered by `longest_win_streak DESC` so the top performers appear first.
