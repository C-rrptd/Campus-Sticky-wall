#!/usr/bin/env bash
# Package the static site for deployment (no bundling/compilation: files are
# copied as-is). Only public files are included; tests, SQL and functions are
# not served. If PUBLIC_* variables are set, assets/js/config.js is generated
# from them (static hosts do not read .env files).
#
#   PUBLIC_SUPABASE_URL=https://<ref>.supabase.co \
#   PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_... \
#   PUBLIC_SITE_URL=https://campus-sticky-wall.pages.dev \
#   scripts/build-site.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-dist}"
case "$OUT" in ""|"/"|"."|"..") echo "refusing to use output dir '$OUT'" >&2; exit 1 ;; esac

if [[ -e "$OUT" ]]; then
  [[ -f "$OUT/index.html" ]] || { echo "$OUT exists and is not a previous build; choose another dir" >&2; exit 1; }
  rm -rf -- "$OUT"
fi
mkdir -p "$OUT"
cp -R index.html _headers components assets "$OUT/"

if [[ -n "${PUBLIC_SUPABASE_URL:-}" || -n "${PUBLIC_SUPABASE_PUBLISHABLE_KEY:-}" || -n "${PUBLIC_SITE_URL:-}" ]]; then
  : "${PUBLIC_SUPABASE_URL:?set PUBLIC_SUPABASE_URL}" "${PUBLIC_SUPABASE_PUBLISHABLE_KEY:?set PUBLIC_SUPABASE_PUBLISHABLE_KEY}" "${PUBLIC_SITE_URL:?set PUBLIC_SITE_URL}"
  # Only sb_publishable_… or a legacy JWT with role "anon" may ship to browsers.
  # sb_secret_… and legacy service_role JWTs bypass RLS and must never be public.
  key_kind=$(python3 - "$PUBLIC_SUPABASE_PUBLISHABLE_KEY" <<'PY'
import base64, json, re, sys
key = sys.argv[1]
if re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]+", key):
    print("public"); sys.exit()
if key.startswith("sb_secret_"):
    print("secret"); sys.exit()
parts = key.split(".")
if len(parts) == 3:
    try:
        seg = parts[1] + "=" * (-len(parts[1]) % 4)
        role = json.loads(base64.urlsafe_b64decode(seg)).get("role")
        print("public" if role == "anon" else "secret"); sys.exit()
    except Exception:
        pass
print("unknown")
PY
)
  if [[ "$key_kind" == "secret" ]]; then
    echo "PUBLIC_SUPABASE_PUBLISHABLE_KEY is a SECRET key (sb_secret_ or non-anon JWT such as service_role). Use the publishable key and rotate the secret now." >&2
    exit 1
  elif [[ "$key_kind" != "public" ]]; then
    echo "PUBLIC_SUPABASE_PUBLISHABLE_KEY is not a publishable key (expected sb_publishable_… or the legacy anon JWT)." >&2
    exit 1
  fi
  for v in "$PUBLIC_SUPABASE_URL" "$PUBLIC_SUPABASE_PUBLISHABLE_KEY" "$PUBLIC_SITE_URL"; do
    [[ "$v" =~ ^[A-Za-z0-9_.:/=+-]+$ ]] || { echo "unexpected characters in a PUBLIC_* value" >&2; exit 1; }
  done
  python3 - "$OUT/assets/js/config.js" <<PY
import re, sys
path = sys.argv[1]
src = open(path).read()
for key, val in (("supabaseUrl", "$PUBLIC_SUPABASE_URL"), ("supabasePublishableKey", "$PUBLIC_SUPABASE_PUBLISHABLE_KEY"), ("siteUrl", "$PUBLIC_SITE_URL")):
    src, n = re.subn(rf'({key}:\s*)"[^"]*"', rf'\g<1>"{val}"', src, count=1)
    assert n == 1, key
open(path, "w").write(src)
PY
  echo "config.js generated for $PUBLIC_SITE_URL"

  # Tighten the CSP: allow only THIS Supabase project (not every *.supabase.co),
  # and drop wss: (realtime is not used).
  python3 - "$OUT/_headers" "$PUBLIC_SUPABASE_URL" <<'PY'
import re, sys
path, url = sys.argv[1], sys.argv[2].rstrip("/")
src = open(path).read()
src, n = re.subn(r" wss://\*\.supabase\.co", "", src)
src, m = re.subn(r"https://\*\.supabase\.co", url, src)
assert m == 3, "expected connect-src, img-src and media-src wildcards"
open(path, "w").write(src)
PY
fi

# Nothing secret may ship to browsers.
if grep -rEq 'sb_secret_[A-Za-z0-9_-]{8,}|SB-Mid-server-[A-Za-z0-9_-]{8,}|Mid-server-[A-Za-z0-9_-]{16,}|"role" *: *"service_role"' "$OUT"; then
  echo "Refusing: a secret-looking value is present in $OUT" >&2
  rm -rf -- "$OUT"
  exit 1
fi
python3 - "$OUT" <<'PY'
import base64, json, pathlib, re, sys
for f in pathlib.Path(sys.argv[1]).rglob("*"):
    if not f.is_file() or "vendor" in f.parts:
        continue
    for tok in re.findall(r"eyJ[A-Za-z0-9_-]{10,}\.(eyJ[A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{10,}", f.read_text(errors="ignore")):
        try:
            role = json.loads(base64.urlsafe_b64decode(tok + "=" * (-len(tok) % 4))).get("role")
        except Exception:
            role = None
        if role != "anon":
            sys.exit(f"Refusing: non-anon JWT found in {f}")
PY
echo "Site packaged in $OUT/"
