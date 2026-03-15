# Provly

**We Got Compliance. You Got Care.**

The only compliance platform built specifically for DSPD providers. A product of Hope Haven Services Inc.

---

## Deploy to Vercel

```bash
# 1. Push to GitHub
cd provly-landing
git init
git add .
git commit -m "Provly v1.0 — landing page"
gh repo create provly-landing --public --source=. --push

# 2. Deploy
vercel --prod

# 3. Connect domain (Vercel Dashboard → Settings → Domains)
# Add: getprovly.com
# DNS at registrar:
#   A Record → 76.76.21.21
#   CNAME (www) → cname.vercel-dns.com
```

## Stack

- React 18 (CDN) + Babel standalone
- Fonts: Google Fonts (Outfit + Manrope)
- Hosting: Vercel
- Domain: getprovly.com

---

© 2026 Hope Haven Services Inc.
