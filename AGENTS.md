# AGENTS.md

Working notes for AI coding agents in baskingspot/utf.

## What this is

SIMD UTF-8, UTF-16, and UTF-32 validation and transcoding, and base64, in Zig, with no C: what simdutf does, as a Zig package. It is incubating: unstable, with no promises about its API.

The repository lives at `baskingspot/utf` on GitHub, where the workflows under `.github/` run, and is mirrored on Amp at https://ampcode.com/@rockorager/utf so project orbs can work on it in parallel. Orbs push branches to Amp; merged `main` goes to both.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit. `.agents/setup` installs Nix when an orb lacks it and warms the dev shell.

## Performance

Speed is the reason this package exists, and memory counts as much as speed. simdutf (C++) is the bar on every operation and input it shares with us; Rust's `simdutf8` and `base64-simd`, Go's standard library, and Zig's `std.unicode` and `std.base64` are comparison arms.

- SIMD with `@Vector` and `std.simd`, no inline assembly unless a measured gain needs it. The scalar path handles tails and is the reference.
- Measure on realistic inputs: ASCII, Latin text, and the CJK, Arabic, Hindi, emoji, and mixed corpora simdutf benchmarks with, at sizes from tens of bytes to megabytes. Short inputs matter: a fast path that loses on 16 bytes is a regression for most callers.
- A change to a hot path comes with an interleaved A/B, pinned to one core, compared with benchstat, written up in `docs/slop/results/<topic>-<yyyymmdd>.md` with the raw output, throughput in GB/s and the CPU named. A speed change that costs memory, or the reverse, is measured both ways.
- No allocation in validation or transcoding: callers pass output buffers, and length functions say how big.

## Tests

`src/scalar.zig` is the reference: every SIMD function returns exactly what its scalar counterpart returns, error kind and position included. Test each SIMD path differentially against the scalar one, with random and adversarial inputs that put every error kind at every position within and across vector blocks and at the end of the input. Error kinds and positions match simdutf's, so simdutf can be a second oracle.

## Agent notes

Docs split by reader. `README.md` and `CHANGELOG.md` are for a person deciding whether and how to use the package. Agent material goes in `docs/slop/`: design notes, plans, and measurements in `docs/slop/results/`. `docs/slop/plan.md` is the architecture, the decisions still to measure, and who owns which files; read it before starting work, and update it when a decision lands. `AGENTS.md` and code comments may link `docs/slop/`; no human document links or names it.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history. A change made for a measurement adds a short body that names its `docs/slop/results/` file and gives the headline number.
- Gate commands on their exit codes, and claim only what you ran.
- `just fmt` formats Zig, Nix, Markdown, and the justfile; `just lint` checks them and lints the workflows with actionlint and zizmor.
- This repo's GitHub settings come from `baskingspot/.github`: run `just settings --repo utf` in a checkout of that repo. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
