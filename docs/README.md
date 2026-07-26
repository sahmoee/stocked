# Stocked — documentation

Everything that isn't source code lives here, in three groups.

## platform/

The business and infrastructure layer — who runs what, and the rules it operates under.

| File | What it covers |
|---|---|
| [PLATFORM_ROLES.md](platform/PLATFORM_ROLES.md) | Which service does what: Cloudflare Worker, Namecheap, Netlify, TestFlight |
| [PLATFORM_SETUP_STEP_BY_STEP.md](platform/PLATFORM_SETUP_STEP_BY_STEP.md) | Setting the platform up from scratch |
| [SOWENS_STUDIOS.md](platform/SOWENS_STUDIOS.md) | Brand, domain (sowensstudios.com), support address, infrastructure facts |
| [COMPLIANCE.md](platform/COMPLIANCE.md) | Privacy, data handling, App Store requirements |

## engineering/

How the app is built and how to check it still works.

| File | What it covers |
|---|---|
| [IMPLEMENTATION_NOTES.md](engineering/IMPLEMENTATION_NOTES.md) | Architecture decisions and the reasoning behind them |
| [CHANGELOG.md](engineering/CHANGELOG.md) | Release history |
| [what-to-test.txt](engineering/what-to-test.txt) | Manual QA checklist |
| [worker.md](engineering/worker.md) | Cloudflare Worker: endpoints, deployment, environment |
| RL-001-002 · RL-003-006 · RL-007-010 · RL-008-009 | Release-log detail for individual work items |

## roadmap/

What's been built, what's next, and why.

| File | What it covers |
|---|---|
| [15_Big_Features.md](roadmap/15_Big_Features.md) | First feature proposal set |
| [15_More_Features.md](roadmap/15_More_Features.md) | Second set — **these 15 are built and shipped in `Stocked/`** |
| [20_Ways_To_Improve_Current_Features.md](roadmap/20_Ways_To_Improve_Current_Features.md) | Improvement audit of existing features, ranked by value ÷ effort |
| [IMPLEMENTED.md](roadmap/IMPLEMENTED.md) | Which of those 20 are done, what changed, and the 4 that need a manual step |
| [FUTURE_IDEAS.md](roadmap/FUTURE_IDEAS.md) | Unscheduled ideas |

---

## Repository layout

```
Stocked 2/
├── README.md                    project overview
├── Secrets.example.xcconfig     key template (copy to Secrets.xcconfig, gitignored)
├── stocked.command              build/run helper
├── swift6_concurrency_guard.sh  pre-build concurrency check
│
├── Stocked/                     ← app source (folder-synchronised: files here auto-compile)
├── Stocked.xcodeproj/
├── StockedTests/
├── StockedWidgets/
├── StockedShareExtension/
├── Icons.xcassets/              ingredient icon catalogue
│
├── stocked-receipt-worker/      Cloudflare Worker (all backend AI routes)
├── content/                     recipe JSON + images served to the app
├── site/                        sowensstudios.com static site
└── docs/                        you are here
```

### Source of truth

`Stocked/` is the only place app source should exist. Copies of `.swift` files kept anywhere
else go stale silently — this repository previously held fifteen source files under
`Feature_Sources/` that were three sessions out of date while looking authoritative. They've been
removed. If you need a snapshot, use a git tag or branch, not a folder.
