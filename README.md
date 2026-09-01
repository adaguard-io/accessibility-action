# ADAGuard Accessibility Scan

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-ADAGuard%20Accessibility%20Scan-blue?logo=github)](https://github.com/marketplace/actions/adaguard-accessibility-scan)

Scan a URL for WCAG 2.2, ADA, Section 508 and EAA violations, and fail the build when the score drops.

```yaml
- uses: adaguard-io/accessibility-action@v1
  with:
    api-key: ${{ secrets.ADAGUARD_API_KEY }}
    url: https://staging.example.com
```

## Gate a pull request

```yaml
name: Accessibility
on: pull_request

permissions:
  contents: read
  pull-requests: write   # only needed for the PR comment

jobs:
  accessibility:
    runs-on: ubuntu-latest
    steps:
      - uses: adaguard-io/accessibility-action@v1
        with:
          api-key: ${{ secrets.ADAGUARD_API_KEY }}
          url: ${{ steps.deploy.outputs.preview-url }}
          min-score: 90
```

The build fails below `min-score`, and results are posted as a single PR comment that is updated in
place on each push rather than stacked.

## Get an API key

Create a key at [app.adaguard.io](https://app.adaguard.io) → Settings → API Keys and add it as a
repository secret. **API access requires a Professional plan or above.**

## Scan more than one page

`scan-mode` defaults to `single`, which scans just the URL you pass — fast and predictable, so a
score change means a real change. To cover more, pick a discovery mode **and raise `max-pages`**:

```yaml
      - uses: adaguard-io/accessibility-action@v1
        with:
          api-key: ${{ secrets.ADAGUARD_API_KEY }}
          url: https://example.com
          scan-mode: sitemap
          max-pages: 50
```

| Mode | What it does |
|---|---|
| `single` | Scans only the given URL. |
| `crawl` | Follows internal links up to `max-pages`. |
| `sitemap` | Reads `sitemap.xml`, then crawls those URLs. |
| `layout` | Crawls, then skips structurally duplicate pages. |

`max-pages` and `include-subdomains` apply to the crawl modes only. Leaving `max-pages` at its
default of 1 while choosing a crawl mode logs a warning, since it would quietly behave like `single`.

## Scan pages behind a login

Capture the session once in the dashboard (Settings → Authenticated Targets), then reference it:

```yaml
      - uses: adaguard-io/accessibility-action@v1
        with:
          api-key: ${{ secrets.ADAGUARD_API_KEY }}
          url: https://staging.example.com/dashboard
          auth-target: latest      # or a target_key like 'production-admin'
```

The target key is a stable alias — recapturing the session does not change it, so the value keeps
working and no secret needs rotating. `latest` uses your most recently captured session.

**If the session has expired, the build fails.** The scan falls back to public pages, which means the
pages you meant to test were never reached, so passing would be misleading. The error names the
expired session rather than the score. Authenticated scanning requires a Professional plan or above.

## Inputs

| Input | Default | Description |
|---|---|---|
| `api-key` | — | **Required.** ADAGuard API key. |
| `url` | — | **Required.** Publicly reachable URL to scan. |
| `min-score` | `80` | Fail below this score (0–100). |
| `scan-mode` | `single` | `single`, `crawl`, `sitemap`, or `layout`. |
| `max-pages` | `1` | Max pages in crawl modes. Capped by your plan. |
| `include-subdomains` | `true` | Crawl subdomains of the target host. |
| `auth-target` | — | Target key, or `latest`, for scanning behind a login. |
| `fail-on-scan-error` | `false` | Also fail when the scanner itself errors. |
| `comment-on-pr` | `true` | Post/update a PR comment. |
| `max-wait-minutes` | `30` | Stop waiting after this long. |
| `idempotency-key` | run + attempt | Dedupe key (see below). |

## Re-runs don't cost a second scan

Each scan counts against your monthly quota, so re-running a job after a network flake should not
spend another one. By default the action sends an idempotency key derived from the run and attempt
(`gha-<run_id>-<attempt>`); if a scan was already created with that key in the last 24 hours, the API
returns the original result instead of starting a new scan.

- **Re-running the same attempt** (a transient failure, an infra retry) reuses the scan — no quota spent.
- **A fresh "Re-run all jobs"** increments the attempt, so you get a new scan, which is usually what you want.
- Pass your own `idempotency-key` (for example the commit SHA) to change that grouping, or set it to a
  unique value each time to always force a fresh scan.

## Outputs

| Output | Description |
|---|---|
| `score` | Score out of 100. Empty when the scan errored. |
| `passed` | Met `min-score`. Also `false` when an authenticated scan fell back to public pages. |
| `critical` / `warning` / `info` | Issue counts by severity. |
| `pages` | Pages actually scanned. |
| `scan-id` | Scan ID, for fetching the report later. |
| `scan-status` | `completed` or `failed`. |
| `auth-status` | `not_requested`, `authenticated`, `expired_fallback`, or `public_only`. |
| `dashboard-url` | Human-readable report. Requires signing in to the account owning the API key, so collaborators without that account cannot open it. |
| `report-url` | JSON report endpoint, fetchable with your API key. |

```yaml
      - uses: adaguard-io/accessibility-action@v1
        id: a11y
        with:
          api-key: ${{ secrets.ADAGUARD_API_KEY }}
          url: https://example.com

      - if: steps.a11y.outputs.critical != '0'
        run: echo "::notice::${{ steps.a11y.outputs.critical }} critical issues"
```

## How failures are treated

A scanner error is not an accessibility regression, so the two are handled differently:

| Situation | Result |
|---|---|
| Score below `min-score` | Build fails. |
| Authenticated session expired | Build fails — the intended pages were never scanned. |
| Scanner errored (network, timeout) | Warns and passes. Set `fail-on-scan-error: true` to fail instead. |
| Scan stuck in the queue over 10 min | Build fails, asking you to re-run. |
| Scan still running after `max-wait-minutes` | Build fails, so a stuck scan cannot drain your runner budget. |

## Timing

About 10 seconds per page, or 13 with `auth-target`. A `single` scan takes well under a minute;
50 pages takes 8–11 minutes, 100 pages 15–20. Raise `max-wait-minutes` above its 30-minute default
for anything past roughly 150 pages.

## Requirements

Runs on any runner with `bash`, `curl` and `jq`. All three are present on
GitHub-hosted runners; on self-hosted, install `curl` and `jq` first — the
action checks for them and stops with a clear message before using your quota.

## Security

The API key is sent only to the API host, as a header. It is never printed or
written to disk. Store it as a repository secret, never in the workflow file.
See [SECURITY.md](SECURITY.md).

## Development

```bash
bash ./script/test-local.sh    # runs the action's real steps against a mock API
```

The harness extracts each step from `action.yml` rather than duplicating it, so the tests cannot
drift from what ships.

## License

MIT
