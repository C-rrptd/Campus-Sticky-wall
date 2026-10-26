// Loads trusted, local HTML fragments (components/*.html) that contain only
// <template> elements, and clones templates by id. Fragments with scripts or
// inline event handlers are rejected.

const loaded = new Map(); // name -> Promise<void>
const NAME = /^[a-z][a-z0-9-]{1,40}$/;

function store() {
  let host = document.getElementById("template-store");
  if (!host) {
    host = document.createElement("div");
    host.id = "template-store";
    host.hidden = true;
    document.body.append(host);
  }
  return host;
}

export function loadComponent(name) {
  if (!NAME.test(name)) return Promise.reject(new Error(`Invalid component name: ${name}`));
  if (loaded.has(name)) return loaded.get(name);
  const promise = (async () => {
    const url = new URL(`../../components/${name}.html`, import.meta.url);
    const res = await fetch(url, { credentials: "same-origin", cache: "no-cache" });
    if (!res.ok) throw new Error(`Component "${name}" failed to load (${res.status}).`);
    const html = await res.text();
    if (/<script\b/i.test(html) || /\son[a-z]+\s*=/i.test(html)) {
      throw new Error(`Component "${name}" contains executable markup and was rejected.`);
    }
    const doc = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html");
    const templates = doc.querySelectorAll("template[id]");
    if (templates.length === 0) throw new Error(`Component "${name}" has no templates.`);
    const host = store();
    templates.forEach((tpl) => {
      if (!document.getElementById(tpl.id)) host.append(document.importNode(tpl, true));
    });
  })();
  loaded.set(name, promise);
  promise.catch(() => loaded.delete(name)); // allow retry after a failure
  return promise;
}

export function loadComponents(names) {
  return Promise.all(names.map(loadComponent));
}

/** Clone a template's content. Throws if the template is missing. */
export function cloneTemplate(id) {
  const tpl = document.getElementById(id);
  if (!(tpl instanceof HTMLTemplateElement)) throw new Error(`Template "${id}" is not loaded.`);
  return tpl.content.cloneNode(true);
}
