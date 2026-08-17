# Changelog

## v1.0.0

First release.

- Scans a URL through the ADAGuard public API and gates the build on `min-score`.
- `single`, `crawl`, `sitemap` and `layout` discovery modes, with `max-pages`
  and `include-subdomains` for the crawl modes.
- Authenticated scanning via `auth-target`, accepting a target key or `latest`.
- Fails the build when an authenticated session has expired, because the pages
  the scan was meant to cover were never reached.
- Treats a scanner error as a warning rather than an accessibility regression,
  unless `fail-on-scan-error` is set.
- Posts a pull request comment that updates in place instead of stacking.
- Sends an idempotency key by default (derived from the run and attempt), so
  re-running a job after a transient failure reuses the scan instead of
  spending another one from your monthly quota.
