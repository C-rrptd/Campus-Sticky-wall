// Deletes Storage files for notes that were removed, rejected, withdrawn or deleted.
// The database queues the paths (media_orphans); this empties the queue. It never
// throws: moderation must not fail because Storage is slow or down. Anything left
// is picked up by the next call.

import type { Deps } from "./auth.ts";
import { rpc } from "./security.ts";

export async function purgeMediaOrphans(deps: Deps, limit = 50): Promise<number> {
  if (!deps.storage && !deps.r2) return 0;
  try {
    const paths = await rpc<string[]>(deps.db, "media_take_orphans", { p_limit: limit });
    if (!Array.isArray(paths) || paths.length === 0) return 0;
    // R2 entries are queued as "r2:<path>"; the thumbnail sibling goes with the file.
    const r2Keys = deps.r2 ? paths.filter((p) => p.startsWith("r2:")).map((p) => p.slice(3)) : [];
    const sbPaths = deps.storage ? paths.filter((p) => !p.startsWith("r2:")) : [];
    if (r2Keys.length) await deps.r2!.remove(r2Keys.flatMap((k) => [k, k.replace(/\.[A-Za-z0-9]+$/, "-t.webp")]));
    if (sbPaths.length) await deps.storage!.remove(sbPaths);
    const done = [...r2Keys.map((k) => `r2:${k}`), ...sbPaths];
    await rpc(deps.db, "media_forget_orphans", { p_paths: done });
    return done.length;
  } catch (err) {
    console.error("media purge failed", err instanceof Error ? err.message : String(err));
    return 0;
  }
}
