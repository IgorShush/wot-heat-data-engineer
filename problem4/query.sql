-- =============================================================================
-- WoT HEAT Data Engineer Test Task
-- Problem 4: Per-player per-day metrics
-- Dialect: PostgreSQL
-- Author: Igor Shushkov
--
-- For each player and each day, return in ONE row:
--   1. damage_dealt   from their 7th WINNING battle that day
--   2. kills          from their 3rd LOSING  battle that day
--   3. started_at     of their 1st DRAW      battle that day
--
-- All three values are NULL when the player did not reach that
-- threshold on a given day (e.g. fewer than 7 wins).
-- =============================================================================


WITH

-- -----------------------------------------------------------------------------
-- Step 1: battle_results
-- Join participants → battles → stats.
-- Classify each battle as 'win', 'loss', or 'draw' from the player's perspective.
-- Convert the UTC timestamp to a calendar date for day-level grouping.
--
-- We use (started_at AT TIME ZONE 'UTC')::DATE rather than started_at::DATE
-- because ::DATE alone uses the session timezone, which can shift day boundaries
-- unexpectedly for players and servers across different regions.
-- -----------------------------------------------------------------------------

battle_results AS (
    SELECT
        bp.player_id,
        b.battle_id,
        b.started_at,
        (b.started_at AT TIME ZONE 'UTC')::DATE     AS battle_date,
        CASE
            WHEN b.winning_team = bp.team_number THEN 'win'
            WHEN b.winning_team IS NULL           THEN 'draw'
            ELSE                                       'loss'
        END                                          AS result,
        bps.damage_dealt,
        bps.kills
    FROM battle_participants bp
    JOIN battles             b   ON b.battle_id      = bp.battle_id
    JOIN battle_player_stats bps ON bps.participant_id = bp.participant_id
),

-- -----------------------------------------------------------------------------
-- Step 2: ranked
-- Assign a rank to each battle within the group (player, date, result).
-- This gives an independent counter per result type per player per day:
--   - win #1, win #2, ... win #N  (ordered by time)
--   - loss #1, loss #2, ...
--   - draw #1, draw #2, ...
--
-- battle_id is the tiebreaker when two battles share the same started_at,
-- ensuring a deterministic and stable ordering.
-- -----------------------------------------------------------------------------

ranked AS (
    SELECT
        player_id,
        battle_id,
        battle_date,
        started_at,
        result,
        damage_dealt,
        kills,
        ROW_NUMBER() OVER (
            PARTITION BY player_id, battle_date, result
            ORDER BY started_at, battle_id
        ) AS rn
    FROM battle_results
)

-- -----------------------------------------------------------------------------
-- Step 3: Final SELECT
-- Group by (player, date) and use conditional aggregation to extract
-- exactly the row we care about for each metric.
--
-- MAX() here is not a true aggregation - since each (player, date, result, rn)
-- combination maps to at most one row, MAX() simply surfaces that single value
-- or returns NULL if no matching row exists.
--
-- This produces one output row per player per day that had at least one battle,
-- with NULLs where a threshold was not reached.
-- -----------------------------------------------------------------------------

SELECT
    p.player_id,
    p.username,
    r.battle_date,

    -- Damage dealt in the 7th winning battle of the day
    MAX(CASE WHEN result = 'win'  AND rn = 7 THEN damage_dealt END)  AS damage_dealt_7th_win,

    -- Kills made in the 3rd losing battle of the day
    MAX(CASE WHEN result = 'loss' AND rn = 3 THEN kills        END)  AS kills_3rd_loss,

    -- Date and time of the 1st draw of the day
    MAX(CASE WHEN result = 'draw' AND rn = 1 THEN started_at   END)  AS first_draw_started_at

FROM ranked r
JOIN players p ON p.player_id = r.player_id
GROUP BY p.player_id, p.username, r.battle_date
ORDER BY p.username, r.battle_date;
