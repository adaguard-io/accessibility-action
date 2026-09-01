# ADAGuard Accessibility Scan

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-ADAGuard%20Accessibility%20Scan-blue?logo=github)](https://github.com/marketplace/actions/adaguard-accessibility-scan)

Scan a URL for WCAG 2.2, ADA, Section 508 and EAA violations, and fail the build when the score drops.

```yaml
- uses: adaguard-io/accessibility-action@v1
  with:
    api-key: ${{ secrets.ADAGUARD_API_KEY }}
    url: https://staging.example.com
```

[Full documentation →](https://www.adaguard.io/docs/github-action)

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

The build fails below `min-score`. Results post as one PR comment, updated in place on each push.

## Get an API key

Create a key at [app.adaguard.io](https://app.adaguard.io) → Settings → API Keys and add it as a
repository secret. **API access requires a Professional plan or above.**

## Scan modes

| Mode | What it does |
|---|---|
| `single` | Scans only the given URL. Default. |
| `crawl` | Follows internal links up to `max-pages`. |
| `sitemap` | Reads `sitemap.xml`, then crawls those URLs. |
| `layout` | Crawls, then skips structurally duplicate pages. |

Crawl modes also need `max-pages` raised above its default of 1:

```yaml
          scan-mode: sitemap
          max-pages: 50
```

`max-pages` and `include-subdomains` apply to crawl modes only.

## Scan pages behind a login

Capture the session in the dashboard (Settings → Authenticated Targets), then:

```yaml
          auth-target: latest      # or a target key like 'production-admin'
```

The target key stays the same when you recapture. An expired session fails the build, and the error
names the session rather than the score. Requires a Professional plan or above.

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
| `idempotency-key` | run + attempt | Dedupe key. |

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
| `dashboard-url` | Human-readable report. Requires the account owning the API key. |
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

| Situation | Result |
|---|---|
| Score below `min-score` | Build fails. |
| Authenticated session expired | Build fails. |
| Scanner errored (network, timeout) | Warns and passes. Set `fail-on-scan-error: true` to fail. |
| Scan stuck in the queue over 10 min | Build fails, asking you to re-run. |
| Scan still running after `max-wait-minutes` | Build fails. |

## Quota

Each scan counts against your monthly quota. Re-running the same attempt reuses the scan; **Re-run
all jobs** starts a new one. Set `idempotency-key` to change that grouping.

## Timing

About 10 seconds per page, 13 with `auth-target`. 50 pages takes 8–11 minutes, 100 pages 15–20.
Raise `max-wait-minutes` above its 30-minute default past roughly 150 pages.

## Requirements

Any runner with `bash`, `curl` and `jq`. All three are present on GitHub-hosted runners; install
`curl` and `jq` on self-hosted.

## Security

The API key is sent only to the API host, as a header. It is never printed or written to disk. Store
it as a repository secret. See [SECURITY.md](SECURITY.md).

## License

MIT
