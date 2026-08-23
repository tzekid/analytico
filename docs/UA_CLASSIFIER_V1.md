# User-Agent traffic classifier v1

This document is the normative, auditable contract for D32's collection-time
User-Agent classifier. It produces a traffic class and bounded rule identifier;
it never persists or emits the input User-Agent. D33 classifier v2 composes
this unchanged UA table with bounded hard browser/receipt evidence.

## Source and provenance

The named-crawler review uses
[`monperrus/crawler-user-agents`](https://github.com/monperrus/crawler-user-agents)
at commit `7baee040e86208bfaf24b2815fd8f322318bd2fa` (2026-08-07).
The reviewed `crawler-user-agents.json` bytes have SHA-256
`c36c67f2527f1a5340858d540c732ebbc3ec866cfc0c5717de82b22a1f8dc537`
and size 542,944 bytes. The upstream data is MIT-licensed; attribution is in
`THIRD_PARTY_NOTICES.md` and the license is in
`LICENSES/Crawler-User-Agents.txt`.

Analytico does not copy the complete regex corpus into its binary or release.
The exact pin supplies review provenance for a deliberately smaller table
covering this product's measured and acceptance-fixture families. Updating the
pin or rules requires a new classifier version, an explicit diff review, and
the complete fixture/gate set.

## Output

Classifier version 1 returns exactly one result:

| Traffic class | Numeric value | Meaning |
| --- | ---: | --- |
| `human-presumed` | 1 | No classifier-v1 rule matched; not proof of a human |
| `declared-bot` | 2 | Empty UA or an explicit crawler/bot declaration |
| `automation` | 3 | A headless browser, HTTP client, scraper library, or monitor |
| `excluded` | 4 | Operator tracker/network exclusion; takes precedence over UA |
| `suspected` | 5 | Reserved for later bounded query-time heuristics; never emitted by UA v1 |

The result also carries `classifier_version=1` and an ASCII `bot_rule` of at
most 64 bytes. A no-match result uses an empty rule. The exclusion rules are
`exclude.tracker`, `exclude.network`, and `exclude.both`.

## Matching contract

The input is the request's optional `User-Agent` header after the HTTP layer
has enforced the 1,024-byte limit. Matching performs no allocation and only
ASCII case folding. UTF-8 interpretation, locale rules, regex, and Unicode
normalization are neither needed nor attempted.

Rules are evaluated in table order. The first match wins. The only match modes
are:

- `prefix`: pattern begins at byte zero;
- `substring`: pattern occurs anywhere; and
- `token`: pattern is bounded on both sides by the input edge or a byte that is
  not an ASCII letter or digit.

Every named crawler, monitor, and headless marker uses `token`; an embedded
string such as `NotGooglebotLike` or `MyUptimeRobotTool` therefore does not
classify. Specific names precede generic tokens so diagnostics retain the useful rule.
Only narrow slash-bearing HTTP-client/library markers use prefix or substring.
The compiled v1 table is limited to 64 entries; its longest pattern and rule
identifier are compile-time checked. The accepted rule families are:

| Rule | Class | Mode | Case-insensitive patterns |
| --- | --- | --- | --- |
| `ua.empty` | declared-bot | exact empty input | empty |
| `crawler.google` | declared-bot | token | `Googlebot`, `Google-InspectionTool`, `AdsBot-Google` |
| `crawler.bing` | declared-bot | token | `bingbot`, `BingPreview`, `adidxbot` |
| `crawler.yahoo` | declared-bot | token | `Slurp` |
| `crawler.baidu` | declared-bot | token | `Baiduspider` |
| `crawler.yandex` | declared-bot | token | `YandexBot`, `YandexImages`, `YandexMobileBot` |
| `crawler.duckduckgo` | declared-bot | token | `DuckDuckBot` |
| `crawler.apple` | declared-bot | token | `Applebot` |
| `crawler.majestic` | declared-bot | token | `MJ12bot` |
| `crawler.ahrefs` | declared-bot | token | `AhrefsBot` |
| `crawler.facebook` | declared-bot | token | `facebookexternalhit`, `Facebot` |
| `crawler.openai` | declared-bot | token | `GPTBot`, `ChatGPT-User`, `OAI-SearchBot` |
| `crawler.commoncrawl` | declared-bot | token | `CCBot` |
| `crawler.semrush` | declared-bot | token | `SemrushBot` |
| `crawler.dotbot` | declared-bot | token | `DotBot` |
| `monitor.uptimerobot` | automation | token | `UptimeRobot` |
| `monitor.statuscake` | automation | token | `StatusCake` |
| `monitor.site24x7` | automation | token | `Site24x7` |
| `headless.chrome` | automation | token | `HeadlessChrome` |
| `headless.phantomjs` | automation | token | `PhantomJS` |
| `client.curl` | automation | prefix | `curl/` |
| `client.wget` | automation | prefix | `Wget/` |
| `client.python_requests` | automation | substring | `python-requests/` |
| `client.python_urllib` | automation | substring | `Python-urllib/` |
| `client.go_http` | automation | prefix | `Go-http-client/` |
| `client.scrapy` | automation | substring | `Scrapy/` |
| `client.okhttp` | automation | substring | `okhttp/` |
| `client.libwww_perl` | automation | substring | `libwww-perl/` |
| `generic.bot` | declared-bot | token | `bot` |
| `generic.crawler` | declared-bot | token | `crawler` |
| `generic.spider` | declared-bot | token | `spider` |

The table intentionally does not treat every occurrence of `bot`, `crawler`,
or `spider` inside an alphanumeric product/model name as a declaration. Cubot,
Abbott, `robotics`, and `SpiderMonkey` are required no-match traps unless an
independent explicit rule is present.

## Historical legacy shadow

During the completed #68 comparison release, the collector also evaluated the
old byte-exact predicate: a case-sensitive substring match for any of `bot`,
`Bot`, `spider`, `Spider`, `crawler`, or `Crawler`. It stores only that boolean
as `legacy_bot_verdict`; it did not retain the header or a second rule.

Traffic-quality diagnostics version 3 compared this boolean with whether UA
classifier v1 returned `declared-bot` or `automation`. Excluded rows take
precedence, store the boolean as false, and are omitted from disagreement cells. Historical rows receive
classifier version zero because their discarded UAs cannot be reconstructed.

For newly inserted nonexcluded rows, `serve_stopped` exposed the same comparison
through six fixed counters: the old-positive and new-positive totals plus
`both_human`, `legacy_only`, `classifier_only`, and `both_bot`. Rejected,
failed, conflicting, duplicate, and excluded observations do not enter these
counters. No counter key or value contained a UA or matched rule. D33 schema 6
removes the comparison byte/counters and promotes permanent class eligibility;
the UA-v1 rule table and its historical classifier-version values remain.

## Privacy, work, and fixtures

- The collector performs zero classifier network requests, file reads,
  allocations, or regex evaluations.
- No raw UA, normalized UA, UA hash, individual rule-input fragment, or exact
  client-hint value is persisted or logged.
- Browser/OS/device classification runs independently; traffic classification
  never uses those derived values as evidence.
- Fixtures cover every row above, upper/lower/mixed case, the 1,024-byte
  boundary, empty and missing headers, first-match ordering, all three modes,
  ordinary current desktop/mobile browsers, embedded named-marker traps, and
  the Cubot/Abbott false-positive traps.
- The #68 real loopback/on-disk journey inspected stored class/version/rule and
  legacy verdict, product eligibility, diagnostic disagreement, raw-UA absence,
  and the matching bounded `serve_stopped` counters before classifier v1 was
  released. D33 fixtures preserve every UA classification while composing hard
  signals and removing only the completed shadow.

D34 does not change this table or emit a new stored UA class. Its query
classifier derives a separate reversible session verdict from schema-7 closed
evidence; stored declared-bot/automation results remain hard exclusions and
stored human-presumed rows remain unchanged. See D34 and
[`METRIC_SEMANTICS_V2.md`](METRIC_SEMANTICS_V2.md) for that relation.
