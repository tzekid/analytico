# Analytico 1.0 design system

Status: normative visual-token contract for Analytico 1.0. Issue #15 owns the
first production mapping. Later shell, component, chart, and mobile work may
consume these tokens but must not silently redefine them.

## Authority and references

`design-tokens.json` is the machine-readable source. `src/web/style.css`
mirrors every token as a CSS custom property using its JSON group and key, for
example `light.brandStrong` becomes `--color-brandStrong` and `space.4`
becomes `--space-4`.

The planning package's written design language, token rules, responsive rules,
and deterministic HTML/CSS prototype clarify intended presentation. The
prototype is a hierarchy and behavior reference, not production markup. The
two AI exploration boards are non-binding and cannot override written product,
accessibility, data, or server-rendering contracts.

## Production mapping

Analytico uses system UI fonts, a Georgia serif wordmark, and tabular lining
figures for metrics, dates, and numeric table cells. It loads no external font
or CSS dependency.

Brand red is an interaction and focus signal, not a status color or page
background. The approved light `brand` token does not provide 4.5:1 contrast
with normal white text, so light links and filled actions use `brandStrong`;
hover uses `brandHover`. Dark links and actions use `brand`. Filled-action text
uses the theme canvas token. These are functional aliases over approved tokens,
not palette changes.

The warm `borderStrong` token is suitable for structural separation but does
not alone reach the 3:1 non-text contrast threshold against every surface.
Inputs and secondary buttons therefore use the approved `inkMuted` token as
their functional control border in both themes.

Successful notices use `positive` and `positiveWash`. Errors use `danger` and
`dangerWash`. Warning tokens are reserved for explicitly labeled incomplete or
risk states; normal warning text uses readable ink on `warningWash` rather than
assuming the warning hue is always a normal-text foreground. Color never
replaces status text, signs, labels, or ARIA roles.

The CSS also defines two non-palette implementation values from the written
design language: 120 ms interaction transitions and a minimal panel shadow.
Reduced-motion preference removes transitions. These do not change the
machine-readable color, spacing, radius, type, or layout tokens.

## Ticket boundary

Issue #15 applied tokens to the existing server-rendered dashboard and owner
authentication pages. Issue #16 consumes the approved 216 px sidebar and
1440 px content tokens for the six-destination shell, with a compact rail at
intermediate widths and complete bottom navigation plus disclosure-based
context at mobile widths. It reuses shipped report/forms content without
claiming the later destination features. Issue #17 owns new shared components,
chart primitives, warning/empty/loading variants, and mobile record tables.
The deterministic prototype remains a hierarchy and responsive-behavior
reference; its markup is not copied as a component framework.

The shared component layer is deliberately smaller than a design-system
framework. It owns context-safe HTML text/attribute escaping and the repeated
KPI, feedback, empty, and form-error-summary semantics. Page composition,
domain tables, native control markup, and product-specific forms remain
explicit. There is no component registry, arbitrary card/widget API, generic
table query DSL, schema-driven form builder, or client state model.

Issue #25 keeps calendar controls explicit rather than adding a generic picker.
The context header contains native preset links, inclusive custom date inputs,
and a comparison select. It prints the selected site's timezone, resolved
comparison dates or an unavailable explanation, and a text marker when today
is incomplete. Pointer and keyboard trend views mark the last current bucket
itself with the visible word
`Incomplete` and a distinct square SVG marker; color is supplementary. The
comparison series is never marked incomplete merely because the current range
contains today. Exact dates remain visible on mobile. Keyboard and
JavaScript-disabled use follows native link, details, select, date-input, and
submit behavior; HTMX may enhance those same GETs and browser history only.
UTC compatibility reports carry a visible warning and are never styled as if
their values used the new local context.

The chart layer exposes exactly five typed families required by the accepted
1.0 screens: trend, horizontal bars, funnel, fixed-column paths, and retention.
Inputs contain raw bounded numeric values plus already formatted labels. A
renderer may write only deterministic HTML/SVG to its supplied writer; it does
not read a database, network, session, filesystem, clock, random source, or
browser state. Document-local IDs are caller-supplied stable ASCII identifiers
and are validated before they enter SVG ID or fragment syntax. Input strings
are escaped for their output context and numeric geometry cannot be supplied as
markup.

Every rendered chart has a visible caption/summary and an adjacent exact table
or details alternative. That alternative prints the raw number used by layout;
optional formatted text is additional and cannot replace it. Missing trend
intervals and incomplete retention cells remain unavailable rather than
becoming zero. Empty, single-point, constant, and all-zero inputs have defined
output. Long series do not make every point a keyboard stop. The fixed path
plot uses three through five columns, no more than eight named nodes plus
`Other` and `No further action` in each column, and direct bounded Bezier
geometry. Its typed input contract requires count-descending nodes with label
tie-breaks, ranked transitions per adjacent step, distinct labels/edges, and
exact incoming/outgoing aggregate totals. On mobile the exact transition list
retains both step and node context and uses that validated ranking;
tables with more than three meaningful columns become labeled records, funnels
stack, and retention keeps a sticky cohort column plus printed values. The
retention renderer follows the functional contract's maximum of 12 cohorts and
12 visible periods, derives each percentage from its raw returned count and
cohort size, and represents incomplete cells separately; later retention work
may show fewer but cannot expand this rendering bound silently.

Issue #28 composes the existing Trend family as at most three separate visual
series after exact-currency expansion. Each figure owns one current line and
its neutral comparison so counts, rates, and amounts never require multiple
axes. One captioned table following the figures aligns all exact series values
and source components by interval, with one native link per current/comparison
label; figures do not duplicate that bounded alternative. The primary series
may carry one text-and-shape `Highlighted` marker for an exact generated
interval; this is distinct from the final-current-bucket `Incomplete` marker.
A result that would exceed three visual series returns an explicit bounded
state rather than truncating currencies or emitting an oversized chart/table
page.

Issue #29 uses the existing mobile-record table and in-cell proportional bar
rather than adding a chart grammar. The first response contains native
Trend/Breakdown mode links, a normal GET builder, bounded observed property
types, search/sort/page controls, exact cardinality or high-cardinality text,
and the complete typed rows. Count, ratio source components, and exact decimal
amount/currency/value-count remain printed; derived bar width is supplementary.
Properties with multiple observed types show each type explicitly, and null and
missing use distinct text labels. The catalog says that its names, types, and
counts come from the latest 2,000 eligible custom events, may update within 30
seconds, and do not replace exact result cardinality; direct property input
remains visible. At mobile width each row retains its dimension/type/metric
context without requiring horizontal navigation or JavaScript.

Issue #30 adds one shared server-rendered filter band to current Overview,
Trend, and Breakdown. A selected segment is visually distinct from ad-hoc
chips; every chip prints scope, field, operator, and exact OR values plus a
native removal link. The filter disclosure remains a normal labeled form with
an explicit Apply action. Its bounded suggestion page names the selected
field/type and whether more values exist; direct typed input remains available.
Stale clauses stay visible with text explaining why execution stopped and one
explicit remove/reset action. Segment and saved-view management uses ordinary
forms, exact-name delete confirmation, and no ambiguous row click.

Breakdown and eligible Overview rows expose separate `Filter` and `Exclude`
links beside any detail link. Desktop and mobile keep those labels; a row itself
never changes meaning according to viewport. All action URLs are controller-
built owned strings. The renderer escapes and writes them without allocation,
query parsing, session access, or I/O. Native POST/303/GET and browser history
are the baseline; HTMX may boost the same controls but adds no client state.

Issue #33 replaces the collapsed raw goal tuple with stable native Goals list,
new, detail, and edit destinations. The first response contains a finite
active/archived list, state text, updated time, selector summary, and ordinary
links for every action. Create/edit forms first choose Page or Event, then show
a bounded search with observed label, eligible count, and last-seen context.
Duplicate copies the exact current selector after a stale-state guard and asks
only for a new unique name. Page prefix is an explicit match choice; no raw
numeric kind or expression syntax is shown.

A manual exact value absent from the current result displays a non-color-only
zero-seen warning and requires a separate confirmation control. Archive and
reactivate are visibly reversible. Delete names the exact goal, requires
confirmation, and renders a 409 reference conflict with an archive action
rather than pretending success. Archived goals remain directly reportable but
are labeled outside the default active set. Empty, no-match, timeout, duplicate
name, invalid selector, stale form, and active-cap states preserve the useful
builder context and focus the error summary.

At phone width the list becomes labeled records, actions retain their names,
controls meet the established touch target, and no primary action clips or
requires horizontal scrolling. Keyboard and JavaScript-disabled users complete
the same GET and POST/303/GET flow. Optional enhancement may submit those exact
forms but cannot add a client router, hidden draft, or selector state model.
Issue #34 adds at most three numbered predicate rows to that same native form.
Each row names the property and selects one visibly typed operator; a value is
required or rejected according to that rule. The server-rendered catalog
repeats a property once per observed scalar type so conflicts are visible
rather than coerced. Preview, zero-match confirmation, and save are distinct submit
intents; timeout/error output preserves the draft and selected context without
client-owned state. Goal detail pairs every KPI/revenue/path value with exact
text/table output and labels capped path/property samples. D43 owns funnel step
composition; #34 does not render fake or disabled funnel controls.

D43 replaces the raw funnel textarea with stable list, new, detail, and edit
pages. The builder renders two through eight numbered step records with named
Page, Event, and Goal choices; direct steps expose at most three of the same
typed predicate controls. Native Add, Remove, Move up, and Move down buttons
submit the complete bounded draft. Order, scope, and window selects explain
consecutive ordering, visitor scope, and cross-session behavior without
claiming that #35 evaluates them.

Preview labels every count as independent selector availability rather than
progression. A zero count and an archived or missing Goal reference use visible
text and not color alone. At phone width the numbered records stack without
clipping, every move/action keeps a visible name and 44-pixel target, and the
same forms work with JavaScript disabled. Optional enhancement may replace only
the submitted builder region; it owns no hidden draft or alternate step order.

D44 places a separate ordered result after a successful preview and on saved
detail. Horizontal proportional bars use the raw current entrant count as
their scale and may add a neutral comparison outline; they never use a
decorative funnel shape. Visible summary text names Sessions or persistent
Visitors and reports entrants, completions, conversion, and total median.
Every step shows its raw count, entrant rate, prior-step rate, drop-off
count/rate, and median from the prior step. The exact table includes every
current and requested comparison value even when the SVG omits a label for
space. Visitor coverage names excluded ephemeral and legacy-daily step-one
identities. No entrants and no progression are different visible states, and
consecutive mode explains that meaningful detours disqualify. Values,
unavailable medians,
and comparison are distinguishable without color. At phone width the figure
and labeled table records stack without page-level horizontal overflow.

D45 renders Sessions as a dense ordered record list rather than a chart or a
clipped wide table. Each record keeps visible Start, Identity, Acquisition,
Landing, Country, Device/browser, Duration, Active engagement, Page views,
custom events, Conversions (Goal matches), Revenue, and Last activity labels.
Exact currencies remain separate lines. `Current` includes the text
`activity received within 30 minutes`; color is supplementary and no status
implies a live connection.
Custom-only and missing-engagement states use explicit text rather than empty
layout gaps.

The active Goal selector is an ordinary GET form and FilterSet/segment controls
reuse the existing native forms. Previous and next are named links. At phone
width every record becomes a single labeled grid, primary controls retain
44-pixel targets, and no field requires horizontal page scrolling. #41 emits no
dead session-detail link before #42 supplies that destination.

D46 turns the Session heading into an ordinary native detail link. The detail
uses a two-column desktop hierarchy with a summary/context region and a
chronological timeline; phone width stacks them in reading order. Every entry
has a visible local time, type, path or event name, and applicable properties,
traits, Goal names, exact value, or engagement summary. Engagement copy says
how many transport fragments were combined and never resembles replay.
`Current` says that activity is incomplete by the same 30-minute receipt rule;
missing engagement says so explicitly.

Compatible identified and persistent-anonymous identities receive a named
profile link. The profile distinguishes **Retained history** totals from
**Sessions matching this context**, labels explicit-link versus anonymous-only
identity, and states that retention may remove older activity. Ephemeral and
legacy identities have no disabled or dead profile control. Rejected conflicts
are described as not merged; Live remains the diagnostic-reason destination.
At phone width the timeline and related sessions remain labeled vertical
records with no unavoidable page-level overflow.

Server validation renders one focused error summary and associates only the
affected form fields with that summary while preserving submitted values.
Notices use restrained status semantics, errors use alerts, and loading is
limited to the region whose existing native navigation or form is in flight.
None of these enhancement states may replace the JavaScript-free baseline.

The component stylesheet is self-hosted at a versioned `/admin/app.v16.css` path.
Changing its bytes requires another path revision because existing responses
may be cached privately for 24 hours.

## Verification

`zig build test` parses `design-tokens.json`, verifies that every token has an
exact production CSS declaration, checks the intended normal-text contrast
pairs, rejects external CSS/font loading, and exercises bounded chart layout,
escaping, ID validation, degenerate inputs, and exact alternatives. The real
dashboard browser scenario checks computed light and dark theme values,
functional action/link mappings, numeric figures, wordmark typography, semantic
figure/table equivalence, focused errors, mobile record/funnel behavior,
reduced motion, keyboard order, and touch targets.

The production budget remains 12 KiB gzip for CSS. Record raw and gzip bytes in
the issue/PR evidence using the exact embedded stylesheet served by the real
dashboard route. Light, dark, desktop, and mobile review compares hierarchy and
semantics with the deterministic references rather than requiring pixel
identity.
