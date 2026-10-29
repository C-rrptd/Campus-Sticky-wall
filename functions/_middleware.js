// Send the old *.pages.dev address to the custom domain. Only the exact production host:
// preview deploys (<hash>.campus-sticky-wall.pages.dev) and local dev pass through.
// shortcut: 302 while the new domain is being verified, switch to 301 once it is stable.
export const onRequest = ({ request, next }) => {
  const u = new URL(request.url);
  if (u.hostname === "campus-sticky-wall.pages.dev") {
    u.hostname = "campusstickywall.app";
    return Response.redirect(u.toString(), 302);
  }
  return next();
};
