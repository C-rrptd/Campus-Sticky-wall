// LOCAL DEV ONLY: fake Supabase client (signed-in user, canned data). Never deploy.
(() => {
  const user = { id: "00000000-0000-4000-8000-000000000001", email: "dev@local.test", user_metadata: { username: "C_rrptd" } };
  const P = (placement, scope_level, duration_days, price) => ({ id: `${placement}-${scope_level}-${duration_days}`, name: `${placement} ${scope_level} ${duration_days}d`, placement, scope_level, duration_days, price_per_target: String(price), sort_order: 0 });
  const tables = {
    ad_products: [P("featured", "campus", 7, 60000), P("featured", "campus", 14, 100000), P("featured", "global", 7, 300000),
      P("random", "campus", 7, 30000), P("random", "campus", 14, 50000), P("random", "city", 7, 80000)],
    countries: [{ code: "ID", name: "Indonesia" }],
    regions: [{ id: "r1", name: "West Java", country_code: "ID", kind: "province" }],
    cities: [{ id: "c1", name: "Bogor", region_id: "r1" }],
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
    rpc: async () => ({ data: false, error: null }),
    functions: { invoke: async (name, o) => { (window.__invoked ||= []).push({ name, body: o?.body }); return { data: { price: "60000", id: "mock" }, error: null }; } },
    storage: { from: () => ({ upload: async () => ({ error: null }) }) },
  };
  window.supabase = { createClient: () => client };
})();
