// Plain-text email through Resend (https://resend.com/docs/api-reference/emails/send-email).
// Does nothing when RESEND_API_KEY is not set, and never throws: a failed email must not undo the
// admin decision that triggered it. Secrets: RESEND_API_KEY, EMAIL_FROM (e.g. "Campus Sticky Wall <hello@yourdomain>").

export async function sendEmail(
  env: (k: string) => string | undefined,
  fetchFn: typeof fetch,
  to: string,
  subject: string,
  text: string,
): Promise<boolean> {
  const key = env("RESEND_API_KEY");
  const from = env("EMAIL_FROM");
  if (!key || !from || !to) return false;
  try {
    const res = await fetchFn("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ from, to: [to], subject, text }),
    });
    if (!res.ok) console.error("Email send failed", res.status);
    return res.ok;
  } catch (err) {
    console.error("Email send failed", err instanceof Error ? err.message : String(err));
    return false;
  }
}
