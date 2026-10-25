// Deletes Storage files for notes that were removed, rejected, withdrawn or deleted.
// The database queues the paths (media_orphans); this empties the queue. It never
// throws: moderation must not fail because Storage is slow or down. Anything left
// is picked up by the next call.

import type { Deps } from "./auth.ts";
import { rpc } from "./security.ts";

export async function purgeMediaOrphans(deps: Deps, limit = 50): Promise<number> {
  if (!deps.storage) return 0;
  try {
    const paths = await rpc<string[]>(deps.db, "media_take_orphans", { p_limit: limit });
    if (!Array.isArray(paths) || paths.length === 0) return 0;
    await deps.storage.remove(paths);
    await rpc(deps.db, "media_forget_orphans", { p_paths: paths });
    return paths.length;
  } catch (err) {
    console.error("media purge failed", err instanceof Error ? err.message : String(err));
    return 0;
  }
}
