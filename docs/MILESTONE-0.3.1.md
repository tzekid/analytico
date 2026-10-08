# Milestone 0.3.1: one design across web, iPhone, iPad and Mac

Status: in progress (started 8 October 2026).

The 0.3 apps used stock controls where the workspace had designed ones: a
checkmark menu for the period, a sidebar list as the iPhone's first screen,
no Compare or Filter, system-blue icons on the Mac, stock empty states. The
fix is not to patch the apps alone. The native app designs become the design
system of every frontend, and the web workspace adopts them too.

Source of truth, in the Analytico Sketch document:

- **v5 · Apps · Foundations**: the rules (AF1), the colour tokens for light
  and dark (AF1), the components (AF2, symbols under `App/`) and the screen
  inventory (AF0).
- **v5 · Apps · iPhone**: the phone layout, for the iPhone app and the web
  on phones.
- **v5 · Apps · Mac & iPad**: the desktop and tablet layout, for the Mac and
  iPad apps and the web on wider screens.
- **v5 · Apps · Dark**: the dark palette applied.
- **v5 · Web**: screens only the web has, drawn in the same system.

## Decisions

1. **Native structure, Analytico skin.** Navigation, sheets, popovers and
   bars behave like the platform; colour, type, data and states come from
   the workspace. The web adopts the layout and the components, never fake
   OS chrome: no drawn status bars or traffic lights. Glass is a CSS
   backdrop blur; sheets are dialogs placed at the bottom of the screen.
2. **The system font everywhere**, Quando for titles and numbers. SF Pro on
   Apple devices, Segoe UI on Windows, Roboto on Android and Linux. The web
   stops bundling Roboto.
3. **Dark mode everywhere**, following the system. The palette is AF1's.
4. **Phones navigate with a floating tab bar**: Overview · Pages · Sources ·
   Live · More, in the iPhone app and on the web. On the web, More lists
   every section the web has (dashboards, funnels, replays, heatmaps,
   people, reports and alerts, data health, settings).
5. **The web gets a Live page** (`/{site}/live`), the same as the apps':
   people online now, page views per minute for the last 30 minutes, the
   pages being read and the latest page views.
6. **The period bar and Compare · Filter · Actions on every report.**
   Screens with their own period (Live, Retention) show a tag instead.
7. **Desktop: cards on the canvas.** A floating sidebar, one toolbar row,
   metric cards instead of the metric strip, tables with share bars, page
   details in an inspector beside the table (a sheet on phones).
8. **Web-only content keeps its content** ("What stood out", replays,
   heatmaps, settings) and takes the system's components.

## Parts

### A. Sketch: v5 · Web

The web shell on a desktop browser and on a phone, More on the web, Live,
Settings, Dashboards, Sessions and replays, People. Verification: review
passes until two in a row find nothing.

### B. Web foundations

Tokens (light and dark), the system font, and the shared components:
cards, the period bar, the controls row, tables, sheets, popovers, the
stage. Verification: every e2e suite; the exploration run in light and dark,
desktop and phone, with no horizontal overflow and no unthemed colour.

### C. Web desktop shell and Overview

Floating sidebar, toolbar row, metric cards, chart card, the card rows.
Verification: `ux.mjs` and `browser.mjs`; screenshots against M01.

### D. Web phone shell

Glass header with the site switcher, Quando title, period bar, controls,
floating tab bar, bottom sheets for period, filter and page details, More,
Live. Verification: `ux.mjs` on a phone viewport; screenshots against
I02–I19.

### E. Web pages

Every report and settings page in the new components. Verification: every
e2e suite; the exploration run.

### F. Apple apps

The v5 designs, natively: the iPhone tab bar and screens, the period sheet,
filter sheet, page sheet, states; the iPad and Mac sidebar, toolbar,
popovers, inspector, Settings window and menu bar panel; widgets; the dark
palette as asset colours; the icon set as template images. Verification:
the kit tests, iOS and macOS builds, the Simulator and the Mac against each
frame, and a real iPhone.

### G. Release

Deploy, install on the iPhone and Mac, then a review loop across web and
apps until two passes find nothing.
