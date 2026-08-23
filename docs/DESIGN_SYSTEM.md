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
is incomplete. Exact dates remain visible on mobile. Keyboard and
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

Server validation renders one focused error summary and associates only the
affected form fields with that summary while preserving submitted values.
Notices use restrained status semantics, errors use alerts, and loading is
limited to the region whose existing native navigation or form is in flight.
None of these enhancement states may replace the JavaScript-free baseline.

The component stylesheet is self-hosted at a versioned `/admin/app.v7.css` path.
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
