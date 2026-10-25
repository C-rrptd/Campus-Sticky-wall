// Run with: deno test supabase/functions/_shared/media_test.ts
import type { Deps } from "./auth.ts";
import { purgeMediaOrphans } from "./media.ts";

function fakeDeps(paths: string[], removeFails = false) {
  const calls: string[] = [];
  const deps = {
    db: {
      rpc: (fn: string, args: Record<string, unknown>) => {
        calls.push(fn + (fn === "media_forget_orphans" ? `:${(args.p_paths as string[]).length}` : ""));
        return Promise.resolve({ data: fn === "media_take_orphans" ? paths : null, error: null });
      },
    },
    storage: { remove: (p: string[]) => { calls.push(`remove:${p.length}`); return removeFails ? Promise.reject(new Error("down")) : Promise.resolve(); } },
  } as unknown as Deps;
  return { deps, calls };
}
function eq(a: unknown, b: unknown, msg: string) {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg}: got ${JSON.stringify(a)}`);
}

Deno.test("deletes queued files, then forgets them", async () => {
  const { deps, calls } = fakeDeps(["a/b.jpg", "a/c.mp4"]);
  eq(await purgeMediaOrphans(deps), 2, "count");
  eq(calls, ["media_take_orphans", "remove:2", "media_forget_orphans:2"], "order of calls");
});
Deno.test("does nothing when the queue is empty or Storage is not configured", async () => {
  eq(await purgeMediaOrphans(fakeDeps([]).deps), 0, "empty");
  eq(await purgeMediaOrphans({ db: fakeDeps([]).deps.db } as unknown as Deps), 0, "no storage");
});
Deno.test("keeps the queue and does not throw when Storage fails", async () => {
  const { deps, calls } = fakeDeps(["a/b.jpg"], true);
  eq(await purgeMediaOrphans(deps), 0, "count");
  eq(calls, ["media_take_orphans", "remove:1"], "must not forget on failure");
});
