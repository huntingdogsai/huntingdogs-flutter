# Flutter Web Runtime Parity Contract

## User-visible promise

After an application wraps its root with `OperatorAppHost`, Watchdog can inspect and operate
ordinary Flutter Web controls with the same model-facing capabilities as ordinary React/Web
controls. A developer does not annotate each button, input, list, or scroll view.

The model receives one joined view of:

- current Flutter control values and state;
- current route, forms, application state, network, storage, logs, and errors;
- exact rendered geometry and exact scroll ownership;
- supported actions for each control;
- a compositor screenshot of the same application state.

## Authority

The normal-control authority is the live Flutter runtime:

```text
Element -> Widget/State -> controller or value owner -> RenderObject -> ScrollableState
```

Flutter Semantics enriches a runtime control with accessibility label, role, hint, and actions when
the semantic node can be joined to that exact rendered control. Semantics does not override a
controller value, enabled state, selected state, rendered geometry, control identity, or scroll
owner. Browser accessibility is not part of normal Flutter control extraction.

The browser compositor screenshot remains visible truth. The in-app repaint-boundary capture is a
supporting Flutter-frame source because browser overlays and platform views can exist outside that
boundary.

## Automatic control inventory

Every current ordinary control is derived from the mounted Element tree. The inventory includes at
least:

- `TextField` and `EditableText`, using the live `TextEditingController` value;
- buttons, links, icon buttons, toggles, checkboxes, radios, switches, tabs, menus, and selections;
- visible `Text` and `RichText`;
- dialogs, routes, focus, enabledness, selection, validation, and secure-field metadata;
- each rendered `ScrollableState` and its live `ScrollPosition`;
- global RenderObject bounds, rendered state, viewport intersection, and supported actions.

Standard Flutter controls require no per-widget declarations. An opaque custom painter that has no
ordinary Flutter control, callback, or usable semantics remains a visual-coordinate fallback, just
as an opaque HTML canvas does in the Web SDK.

## Identity and rebuilds

The SDK keeps private live references to mounted Elements, State objects, controllers, RenderObjects,
and ScrollPositions. The model receives only opaque references issued for one snapshot.

An action resolves its opaque reference against the currently mounted runtime object. If a rebuild
replaced that object, the old reference cannot silently select another control with the same label
or position. The next snapshot issues current references.

## Actions

Flutter exposes the same ordinary action meanings as React/Web:

- tap/click;
- type and clear;
- targeted key input (the SDK establishes exact Flutter focus, then the browser sends the key);
- hover where Flutter Web supports it;
- direct scroll of an exact scroll owner;
- scroll a target into view through its actual owner chain;
- drag and touch gestures;
- waits against current route, UI, form, state, network, and storage.

Pointer actions enter Flutter's production gesture pipeline after the SDK revalidates the exact
mounted target. Targeted keys use the exact live Flutter `FocusNode` and Chrome's browser-owned key
delivery, so Enter, Tab, Escape, and shortcuts follow the Web engine path rather than a testing-only
key shim. They retain the existing Operator result and evidence meanings; this contract does not
introduce Flutter-only action blockers, retries, time limits, or failure categories.

React/Web has no separate public focus, select, or submit command. Flutter therefore does not invent
them: focus supports targeted key/type, and selection or submission is driven through the same
tap/type/key commands. Browser file attachment remains unavailable until a Flutter file-picker
integration can accept generated files without bypassing the plugin that owns the picker.

## Exact scrolling

Every scrollable is a first-class control with current axis, offset, extent, viewport, and geometry.
When revealing a descendant, the runtime derives its ordered `Scrollable` ancestor chain from the
current Element tree; the model-facing descendant does not need a duplicate copy of that chain.

Direct `scroll` resolves the requested scroll-owner control and changes only that `ScrollPosition`.
`scroll_into_view` resolves the requested target and uses Flutter's production reveal behavior
across its real ancestor chain. The SDK never chooses a scrollable because it is the largest
visible candidate.

## Flutter Web bridge

The package must compile for Flutter Web through conditional exports that keep `dart:io`, isolates,
and the in-app HTTP server out of the browser build. The installed app exposes a versioned,
page-local bridge for snapshot, action, event, capability, and health operations.

Watchdog recognizes instrumented Flutter only through that versioned handshake. It joins the
Flutter runtime snapshot with host-owned browser pixels and browser evidence without replacing
Flutter controls with DOM or browser accessibility projections.

## Required proof before parity is claimed

Parity requires all of the following:

1. Controller values win when Semantics is missing or contradictory.
2. Duplicate labels remain distinct through runtime identity and geometry.
3. Replaced controls cannot be acted on through an old snapshot reference.
4. Nested direct scroll mutates only the selected ScrollPosition.
5. Scroll-into-view follows the target's actual owner chain.
6. Standard actions have the same model-facing availability and result meaning as React/Web.
7. State, route, forms, errors, network, storage, and screenshots reach the same host snapshot.
8. A real Flutter Web browser fixture passes in release/static mode and debug mode.
9. QuoteIQ passes a fresh login-flow run without browser AX or screenshot-only action gaps.

Widget tests verify the SDK internals. Real-browser tests verify the compiled Flutter Web artifact,
page bridge, trusted input, compositor pixels, and Watchdog integration. Neither proof substitutes
for the other.

## Root-cause reliability review

- **Symptom:** QuoteIQ visibly contained a prefilled email value while Watchdog's structured Flutter
  UI reported that input as empty, allowing a test with a false precondition to submit a real login.
- **Why 1:** Watchdog treated accessibility-derived field data as current application value truth.
- **Why 2:** the uninstrumented browser path could see Flutter's exported accessibility surface but
  not the `TextEditingController` that owned the field value.
- **Why 3:** the current Flutter SDK also builds its primary UI inventory from Semantics instead of
  defining one runtime-owned control graph that joins Widget, State, controller, RenderObject, and
  Scrollable data before accessibility enrichment.
- **Root cause:** Flutter control identity, current state, geometry, action ownership, and
  accessibility metadata do not yet share one authoritative runtime record.
- **Chosen fix layer:** build that record inside the Flutter SDK and expose it through a web-safe
  bridge; do not patch QuoteIQ or add another screenshot-only heuristic.
- **Reliability planes:** observation truth, state truth, action truth, visual truth, and release
  integrity truth.
- **Related failures:** stale programmatic values, duplicate labels, recycled semantic IDs, wrong
  nested scroll owners, hidden or inactive route controls, replaced widgets, and controls whose
  painted bounds disagree with their semantic bounds.
- **Invariant:** model-facing current values and actions originate from the current mounted Flutter
  object that owns them; Semantics can enrich but cannot override that record, and screenshots
  independently show the visible consequence.
- **Guardrail:** the focused parity fixtures plus the existing Flutter SDK suite, compiled-browser
  fixture, Web host integration smoke, and repeated QuoteIQ flow.
- **Live proof:** no live proof is claimed until the completed package is integrated into a
  disposable QuoteIQ QA build and a fresh Watchdog session demonstrates the full path.
