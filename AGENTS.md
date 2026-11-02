# AGENTS.md

Working notes for AI coding agents in baskingspot/utf.

## What this is

SIMD Unicode validation and transcoding, plus base64, in Zig with no C: what
simdutf does, as a Zig package. The public API moves with semver. Releases are
tags made by `release.yml`, from v0.1.0; a consumer fetches a release's archive,
or pins a commit for work between releases.

`validate` checks UTF-8, ASCII, UTF-16LE/BE, and UTF-32. `convert` moves
between any two of UTF-8, UTF-16LE/BE, UTF-32, and Latin-1, with a checked form
that validates as it writes and a valid form for input already known to be
well-formed. `length` sizes an output and counts code points. `base64` encodes
and decodes with the standard or URL alphabet.

The repository lives at `baskingspot/utf` on GitHub, where the workflows under
`.github/` run.

## Environment

Zig 0.16 and 0.17. The flake is the tool contract, from `baskingspot/nix`:
`nix develop` is the current stable, Zig 0.17, and `nix develop .#zig-old` is
Zig 0.16. Both provide Zig, `ziglint-0-16`, the docs tools, and the base tools,
and nothing comes from the system PATH. The justfile is the command interface:
`just test`, `just check`, `just lint`, `just ci`. Run `just fmt` before you
commit. CI runs `just ci` on the default shell, `just check` on `zig-old`, and
`just check-dispatch` on x86-64.

Version shims live in `src/compat.zig`. Do not write `@intFromEnum`,
`@enumFromInt`, or `**` outside it: 0.17's `zig fmt` migrates the first two,
and 0.17 removed the third. The `// zig fmt: off` block keeps a 0.17 format
from breaking the 0.16 build. Lint with `ziglint-0-16`, which targets the 0.16
std, so 0.17-only deprecations do not fire while 0.16 is supported.

Tests run under testingx, the org's test runner, a lazy dependency. Every
`addTest` carries `.test_runner = .{ .path = dep.path("src/runner.zig"), .mode = .simple }`;
the runner picks and prints its own seed.

The guide's examples in `docs/examples/` compile against the public module and
run with `just test`. A snippet in `docs/content/_index.md` that does not build
is a bug.

## Docs site

The site is served at `https://baskingspot.dev/utf/`. `just doc` builds the
guide (Zola, from `docs/`) and the API reference (docgen JSON, rendered by the
theme's `api.html`) into `zig-out/site/utf/`. `just guide` serves it with live
reload. `docs/config.toml` holds the title and description; `docs/content/`
holds the guide; `docs/static/` holds the marks.

Human docs are `README.md`, the guide, `CHANGELOG.md`, and `bench/README.md`.
Agent material goes in `docs/slop/`. No human document links or names
`docs/slop/`.

## Performance

Speed is the reason this package exists, and memory counts as much as speed.
simdutf (C++) is the bar on every operation and input it shares with us; Rust's
`simdutf8` and `base64-simd`, Go's standard library, and Zig's `std.unicode` and
`std.base64` are comparison arms.

- SIMD with `@Vector` and `std.simd`, no inline assembly unless a measured gain
  needs it. The scalar path handles tails and is the reference.
- Measure on realistic inputs: ASCII, Latin text, and the CJK, Arabic, Hindi,
  emoji, and mixed corpora simdutf benchmarks with, at sizes from tens of bytes
  to megabytes. Short inputs matter: a fast path that loses on 16 bytes is a
  regression for most callers.
- A change to a hot path comes with an interleaved A/B, pinned to one core,
  compared with benchstat, written up in `docs/slop/results/<topic>-<yyyymmdd>.md`
  with the raw output, throughput in GB/s and the CPU named. A speed change that
  costs memory, or the reverse, is measured both ways.
- Local numbers are for iterating. `bench/README.md` says a number that gets
  quoted in a public doc needs a run on dedicated hardware.
- No allocation in validation or transcoding: callers pass output buffers, and
  length functions say how big.

## Tests

`src/scalar.zig` is the reference: every SIMD function returns exactly what its
scalar counterpart returns, error kind and position included. Test each SIMD
path differentially against the scalar one, with random and adversarial inputs
that put every error kind at every position within and across vector blocks and
at the end of the input. Error kinds and positions match simdutf's, so simdutf
can be a second oracle.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed.
  Do not rewrite pushed history on `main`; branches may be rebased and
  force-pushed. A change made for a measurement adds a short body that names
  its `docs/slop/results/` file and gives the headline number.
- Gate commands on their exit codes, and claim only what you ran.
- `just fmt` formats Zig, Nix, Markdown, and the justfile; `just lint` checks
  them and lints the workflows with actionlint and zizmor.
- This repo's GitHub settings come from `baskingspot/.github`: run
  `just settings --repo utf` in a checkout of that repo. Do not change them by
  hand.
- To release, run
  `just --justfile ~/code/baskingspot/.github/justfile release-prep VERSION`,
  review the diff, commit it signed, push, then dispatch `release.yml` with the
  version. The workflow changes no files: it refuses a tag that exists, a
  missing changelog section, or a manifest that names another version, then
  creates the tag and opens the release. Do not tag or commit by hand, and
  never add a commit step to a workflow.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.
