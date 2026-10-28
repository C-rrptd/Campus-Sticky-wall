// LOCAL DEV ONLY: fake Supabase client (signed-in user, canned data). Never deploy.
(() => {
  const user = { id: "00000000-0000-4000-8000-000000000001", email: "dev@local.test", user_metadata: { username: "C_rrptd" } };
  const P = (placement, scope_level, duration_days, price) => ({ id: `${placement}-${scope_level}-${duration_days}`, name: `${placement} ${scope_level} ${duration_days}d`, placement, scope_level, duration_days, price_per_target: String(price), extra_location_pct: 100, sort_order: 0 });
  const tables = {
    ad_products: [P("featured", "campus", 7, 60000), P("featured", "campus", 14, 100000), P("featured", "global", 7, 300000),
      P("random", "campus", 7, 30000), P("random", "campus", 14, 50000), P("random", "city", 7, 80000)],
    countries: [{ code: "ID", name: "Indonesia" }],
    regions: [{ id: "r1", name: "West Java", country_code: "ID", kind: "province" }],
    cities: [{ id: "c1", name: "Bogor", region_id: "r1" }],
    decorations: [
      ["frame-thick", "Thick frame", "Borders", 0, 0], ["frame-dashed", "Dashed frame", "Borders", 1000, 0],
      ["tape-washi-pink", "Pink washi tape", "Tapes", 1000, 0], ["tape-washi-blue", "Blue washi tape", "Tapes", 1000, 0], ["tape-masking", "Masking tape", "Tapes", 0, 0],
      ["sticker-sun", "Sun", "Stickers", 1000, 1, 88, 12], ["sticker-cat", "Cat", "Stickers", 1000, 1, 88, 84], ["sticker-coffee", "Coffee", "Stickers", 1000, 1, 12, 12],
      ["stamp-approved", "Approved stamp", "Stamps & badges", 1000, 1, 50, 88], ["badge-star", "Star badge", "Stamps & badges", 1000, 1, 70, 12],
      ["paper-lined", "Lined paper", "Backgrounds", 1000, 0],
    ].map(([id, name, category, price, placeable, x, y]) => ({ id, name, description: name, category, placeable: !!placeable, default_x: x ?? null, default_y: y ?? null, price: String(price) })),
    campuses: [{ id: "u1", name: "IPB University", short_name: "IPB", city_id: "c1" }],
  };
  const builder = (table) => {
    const b = new Proxy(() => {}, {
      get: (_, k) => (k === "then" ? (res) => Promise.resolve({ data: tables[table] ?? [], error: null }).then(res) : () => b),
    });
    return b;
  };
  const client = {
    auth: { onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }), getSession: async () => ({ data: { session: { user } }, error: null }), signOut: async () => ({ error: null }) },
    from: builder,
    rpc: async (fn) => ({ data: ({
      ad_catalog: tables.ad_products.map((a) => ({ ...a, list_price_per_target: a.price_per_target, discount_pct: 0, launch: false })),
      get_locations_recent_views: [], get_ad_availability: [], list_open_auctions: [], my_auction_offers: [], join_ad_waitlist: { ok: true }, my_price_locks: { founding: false, locks: [], grace_days: 7 },
      get_public_stats: { updated_at: new Date().toISOString(), views_total: 0, clicks_total: 0, views_30d: 0, clicks_30d: 0, locations: [] },
    })[fn] ?? false, error: null }),
    functions: { invoke: async (name, o) => { (window.__invoked ||= []).push({ name, body: o?.body }); return { data: { price: "60000", id: "mock" }, error: null }; } },
    storage: { from: () => ({ upload: async () => ({ error: null }) }) },
  };
  window.supabase = { createClient: () => client };
})();
