# Provly

**We Got Compliance. You Got Care.**

The only compliance platform built specifically for DSPD providers. A product of Hope Haven Services Inc.

---

## Project Structure

```
provly-landing/
├── public/
│   ├── index.html          ← Landing page (getprovly.com)
│   └── app/
│       └── index.html      ← Login + Dashboard (getprovly.com/app)
├── vercel.json              ← Vercel config
├── package.json
├── README.md
└── sql/
    ├── provly_schema.sql
    ├── provly_chunk_1_structure.sql
    ├── provly_chunk_2_indexes_rls.sql
    ├── provly_chunk_2b_rls_retry.sql
    └── provly_chunk_3_functions_seed.sql
```

## Stack

- React 18 (CDN) + Babel standalone
- Supabase (Auth + Postgres + RLS)
- Fonts: Google Fonts (Outfit + Manrope)
- Hosting: Vercel
- Domain: getprovly.com

## URLs

- `getprovly.com` — Marketing / landing page
- `getprovly.com/app` — Login + compliance dashboard

---

© 2026 Hope Haven Services Inc.
