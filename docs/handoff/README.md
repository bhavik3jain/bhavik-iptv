# Hearth — handoff package

Oct 24, 2026 · Bhavik Jain

Everything needed to start building Hearth (a working title): an IPTV player for iPhone, iPad and Mac that does what iSTB does, plus Netflix-style profiles shared by a household through iCloud. Nothing is built yet; this package holds the handoff, the specs and the UI mockups.

## What's inside

| Path | What it is |
| --- | --- |
| `Hearth-Handoff-and-Specs.pdf` | Everything in one file: handoff, product spec, technical spec, source protocols, diagrams and the seven mockup screens |
| `docs/1-Handoff.md` | Decisions, scope, roadmap, risks, open questions, Multitrack lessons, first-week checklist |
| `docs/2-Product-spec.md` | Every requirement with its id and phase |
| `docs/3-Technical-spec.md` | Packages, both data stores, sync rules, player engine, stream limits, testing, release |
| `docs/4-Source-protocols.md` | Stalker portal, Xtream Codes and M3U/XMLTV reference, stable ids, verification checklist |
| `docs/Hearth-Handoff-and-Specs.html` | The four specs as one web page |
| `docs/diagrams/` | Roadmap, navigation, architecture and player-engine drawings |
| `ui/index.html` | Gallery of the UI mockups: open this first |
| `ui/screens/` | The seven screens as standalone pages; the iPhone screens link to each other like a prototype (start at `Main.html`, "Who's watching") |
| `ui/png/` | Each screen as a 2x PNG |
| `ui/source/` | The original design-canvas files (`.dc.html` plus `canvas.json`) |
| `ui/fonts/` | Sora, IBM Plex Sans and IBM Plex Mono (SIL Open Font License 1.1), so the screens render offline |

## The screens

1. Who's watching: profiles, household and stream use
2. Home: continue watching, favorite channels, up next, new movies
3. Live TV guide: timeline, catch-up marks, Watch live and From the start
4. Show detail: seasons, episodes, where each household member is
5. Household and sources: members, stream limits, profiles, sources, sync switches
6. Player, landscape: catch-up timeline, Jump to live, picture in picture, AirPlay, multi-view
7. Mac: sidebar with profile switcher, 2x2 multi-view, now and next

Names, channels and titles in the mockups are placeholders.

## Live versions

The editable doc and the design canvas live on claude.ai; both are private until shared from their Share menu.

- Doc: https://claude.ai/artifact/DF26MwKQkpi3mXiyR4UXi6
- Design canvas: https://claude.ai/artifact/FQKiJK9SuC9Xc2UZ8UFQdi

## Before building

The first open question decides what Phase 1 builds: which kind of login the provider gives (a MAC portal, an Xtream username and password, or an M3U link). Protocol rows marked "unverified" in `docs/4-Source-protocols.md` must be checked against the real provider first.
