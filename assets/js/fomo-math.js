// Pure helpers for the wall's weekly campus race. A week runs Monday 00:00 to Monday 00:00 WIB (UTC+7, no DST),
// the same as campus_leaderboard('week') in migration 051.
const DAY = 864e5;
const WIB = 7 * 3600e3;

/** Milliseconds until the weekly board resets (next Monday 00:00 WIB). */
export function msToWeekEnd(now = Date.now()) {
  const t = now + WIB;
  const day = Math.floor(t / DAY);
  const sinceMonday = (day + 3) % 7; // 1970-01-01 was a Thursday
  return (day - sinceMonday + 7) * DAY - t;
}

/** [unit, n] for the "Resets in n unit" line: days from 2 days out, then hours, then minutes. */
export function leftParts(ms) {
  const m = Math.max(0, Math.floor(ms / 6e4));
  if (m >= 2880) return ["days", Math.floor(m / 1440)];
  if (m >= 60) return ["hours", Math.floor(m / 60)];
  return ["min", m];
}

/** Where a campus stands in campus_leaderboard rows (sorted by rank). null when it is not on the board or has no rival yet.
 *  kind: "ahead" (leading, gap = lead over #2), "tied" (tied for first), "behind" (gap = votes needed to pass the campus above). */
export function rivalry(rows, campusId) {
  const i = rows.findIndex((r) => r.campus_id === campusId);
  if (i < 0 || (i === 0 && rows.length < 2)) return null;
  const mine = Number(rows[i].value);
  const base = { name: rows[i].display_name, rank: Number(rows[i].rank) };
  if (i === 0) {
    const gap = mine - Number(rows[1].value);
    return { ...base, rival: rows[1].display_name, gap, kind: gap > 0 ? "ahead" : "tied" };
  }
  const above = rows[i - 1];
  return { ...base, rival: above.display_name, gap: Number(above.value) - mine + 1, kind: "behind" };
}
