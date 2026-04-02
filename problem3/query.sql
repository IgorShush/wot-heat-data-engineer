-- =============================================================================
-- WoT HEAT Data Engineer Test Task
-- Problem 3: Longest consecutive win streak per player
-- Dialect: PostgreSQL
-- Restriction: no recursive (hierarchical) queries
-- Technique: Gaps and Islands using window functions
-- Author: Igor Shushkov
-- =============================================================================


WITH

-- -----------------------------------------------------------------------------
-- Step 1: battle_results
-- Join participants with battles to determine the outcome for each player
-- in each battle: win, loss, or draw.
--
-- A player wins when their team_number matches the battle's winning_team.
-- A draw occurs when winning_team IS NULL.
-- Everything else is a loss.
-- -----------------------------------------------------------------------------

battle_results AS (
    SELECT
        bp.player_id,
        b.battle_id,
        b.started_at,
        CASE
            WHEN b.winning_team = bp.team_number THEN TRUE
            ELSE FALSE                              -- loss or draw both break win streaks
        END AS is_win
    FROM battle_participants bp
    JOIN battles b ON b.battle_id = bp.battle_id
),

-- -----------------------------------------------------------------------------
-- Step 2: numbered
-- Assign two row numbers per player, both ordered by battle time:
--
--   rn_all         — counts every battle regardless of result
--   rn_partitioned — counts battles partitioned by result (wins separately
--                    from non-wins)
--
-- The KEY INSIGHT of the Gaps and Islands technique:
-- Within a consecutive run of wins, (rn_all - rn_partitioned) is CONSTANT.
-- Any loss or draw increments rn_all but not the wins-only counter,
-- permanently shifting the difference and starting a new "island".
--
-- Example for one player:
--   Battle:          W   W   L   W   W   W   D   W
--   rn_all:          1   2   3   4   5   6   7   8
--   rn_partitioned:  1   2   1   3   4   5   1   6
--   difference:      0   0   2   1   1   1   6   2
--                    \___|       \___|___|       |
--                    streak=2    streak=3    streak=1
-- -----------------------------------------------------------------------------

numbered AS (
    SELECT
        player_id,
        battle_id,
        started_at,
        is_win,
        ROW_NUMBER() OVER (
            PARTITION BY player_id
            ORDER BY started_at, battle_id      -- battle_id breaks ties in started_at
        ) AS rn_all,
        ROW_NUMBER() OVER (
            PARTITION BY player_id, is_win
            ORDER BY started_at, battle_id
        ) AS rn_partitioned
    FROM battle_results
),

-- -----------------------------------------------------------------------------
-- Step 3: streak_groups
-- Filter to wins only, then group by the island key (rn_all - rn_partitioned).
-- Each group is one unbroken win streak; COUNT(*) is its length.
-- -----------------------------------------------------------------------------

streak_groups AS (
    SELECT
        player_id,
        rn_all - rn_partitioned AS island_key,
        COUNT(*)                AS streak_length
    FROM numbered
    WHERE is_win = TRUE
    GROUP BY player_id, rn_all - rn_partitioned
),

-- -----------------------------------------------------------------------------
-- Step 4: max_streaks
-- Take the longest streak per player.
-- Players with no wins at all will not appear here; they are handled in the
-- final SELECT with COALESCE(..., 0).
-- -----------------------------------------------------------------------------

max_streaks AS (
    SELECT
        player_id,
        MAX(streak_length) AS longest_win_streak
    FROM streak_groups
    GROUP BY player_id
),

-- -----------------------------------------------------------------------------
-- Step 5: all_participants
-- Collect every player who took part in at least one battle.
-- The problem requires results for ALL such players, including those with
-- zero wins.
-- -----------------------------------------------------------------------------

all_participants AS (
    SELECT DISTINCT player_id
    FROM battle_participants
)

-- -----------------------------------------------------------------------------
-- Final SELECT
-- Join everything together.
-- COALESCE ensures players with no wins at all show 0, not NULL.
-- -----------------------------------------------------------------------------

SELECT
    p.player_id,
    p.username,
    COALESCE(ms.longest_win_streak, 0) AS longest_win_streak
FROM all_participants ap
JOIN   players     p  ON p.player_id  = ap.player_id
LEFT JOIN max_streaks ms ON ms.player_id = ap.player_id
ORDER BY longest_win_streak DESC, p.username;
