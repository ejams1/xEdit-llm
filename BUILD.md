# Building xEdit from source (this fork)

This documents how to produce a release-style build from this fork's source, and how to tell a build is
good. It is only needed when the fork carries something upstream has not released — see
[When you do not need this](#when-you-do-not-need-this).

Derived from the contributor section of [`README.md`](README.md), plus the package-build order and
verification steps worked out on 2026-09-23.

## When you do not need this

The published `v4.1.6-automation.9` release here is **the upstream `BB-84C/TES5Edit` r9 build, unmodified**,
because this fork's source at that tag is the exact commit upstream built from (zero divergence in either
direction). Its assets hash to the values in that release's notes and to upstream's own published
`SHA256SUMS.txt`.

So: if the fork is level with `upstream/automation-4.1.6`, or the only commits ahead of it touch
documentation, there is nothing to build that is not already released:

```
git log --oneline upstream/automation-4.1.6..HEAD          # empty, or docs-only
git log --oneline upstream/automation-4.1.6..HEAD -- ':!*.md' ':!docs'   # code changes only
```

Rebuild when that second command lists something.

## Requirements

| Requirement | Notes |
|---|---|
| [Delphi 12 Community Edition](https://www.embarcadero.com/products/delphi/starter) | Free, but needs an Embarcadero account and online activation. There is no standalone `dcc64.exe` download; the compiler ships only inside the product install. |
| [Project Magician](https://www.uweraabe.de/Blog/downloads/download-info/project-magician/) | IDE add-on, required by the build as upstream documents it. |
| [DDevExtensions](https://github.com/DelphiPraxis/DDevExtensions/releases) | Then: Tools → DDevExtensions Options → Extended IDE Settings: **enable** *Disable Package Cache*; Form Designer: **enable** *Do not store the Explicit properties into the DFM*. Exit Delphi. |
| Windows x64 + git | Submodules are large; allow a few GB. |
| DevExpress (optional) | Not needed if you build the `LiteDebug` configuration. With it, the full `Debug`/`Release` configurations become available. |

`LiteDebug` exists in `xEdit.dproj`; no DevExpress units are referenced there.

## Build

1. Clone and initialize submodules, then make sure the tree is clean:

   ```
   git clone https://github.com/ejams1/xEdit-llm
   cd xEdit-llm
   git submodule update --init --recursive
   git status --short          # must be empty
   ```

2. Copy the JCL include template for this Delphi version (the generated names are gitignored inside the
   submodule, so this leaves no dirty state):

   ```
   cd External/jcl/jcl/source/include
   cp jcl.template.inc jcld29win32.inc
   cp jcl.template.inc jcld29win64.inc
   ```

3. Build and install the external packages, in this order, restarting Delphi where upstream says to:

   1. `External/jcl/jcl/packages/JclPackagesD290.groupproj` — Build All, then install every non-runtime
      package (green icons).
   2. `External/jvcl/jvcl/packages/D29 Packages.groupproj` — first add to Tools → Options → Language →
      Delphi → *Library*: `External/jcl/jcl/lib/d29/win32` and `External/jcl/jcl/source/include`; Build All,
      install non-runtime packages; then add `External/jvcl/jvcl/lib/d29/win32` and restart.
   3. `External/VirtualTrees/Packages/RAD Studio 12/VirtualTreeView.groupproj` — Build All, install
      `VirtualTreesD29.bpl`.
   4. `External/FileContainer/FileContainer29.groupproj` — Build All, install `FileContainerD29.bpl`.

4. Build the program: open `BethWorkBench.groupproj`, set the Build Configuration to `LiteDebug`
   (required when DevExpress is absent), platform `Win64`, then **Build All**.

   For the automation regression setup, use `LiteDebug`, platform `Win32`, as
   the active/default project configuration and launch the IDE build in the
   background (adjust the installed IDE path):

   ```powershell
   Start-Process 'C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\bds.exe' -WindowStyle Hidden -ArgumentList @('-b', (Resolve-Path xEdit.dproj).Path) -RedirectStandardOutput build.stdout.log -RedirectStandardError build.stderr.log
   ```

   Check the compiler transcript (`xEdit.err` when capture is incomplete) for
   `Building xEdit.dproj (LiteDebug, Win32)` and fresh
   `Temp\xEdit\Win32\LiteDebug` output. Preserve transcript, executable hash and
   source commit with acceptance artifacts. A successful log without a fresh
   executable is insufficient. No Delphi environment is installed in the
   current issue-queue workspace, so compilation is pending.

   `BethWorkBench.groupproj` also builds `BSArch`, `BSArchPro`, `Sniff` and `xDump`; only `xEdit.dproj` is
   needed for the release archive.

## Verify a build

Byte-identity with the reference build is **not** expected: Delphi embeds build timestamps and PDB paths.

Reference (r9):

```
36fcb8d4ef683a0fbbcd30c3652978a93b20d06d21f06fd762aa08116e1d80ef  xEdit.exe   (and xEdit64.exe)
e5e503da99348401e3593718c49ac83c9368446d9df07ad113137cc411c7ec0f  xEdit.4.1.6-automation.9.zip
```

1. **Section comparison.** Hash `.text` and `.rdata` separately from the reference executable and the new
   one (any PE reader works, e.g. Python `pefile`). `.text` is the meaningful one; differences there mean a
   real source or compiler-option difference, while a differing resource/version blob or PE header does not.
2. **Daemon acceptance.** Launch with `-FO4 -automation-serve` using explicit
   game Data and plugin selection under the intended mod-manager VFS. The pipe
   is `\\.\pipe\xedit-<PID>`. Follow the [lifecycle example and fixtures](Tools/AutomationRegression/README.md#daemon-lifecycle): inspect capabilities, read loaded files, verify each intended native mutation, save/flush, relaunch under a fresh PID and read persisted state.
3. Compilation and section comparison support acceptance; they cannot prove
   command behavior. Treat the build as a replacement only after inspected
   native readbacks pass. CI fixture checks make no runtime acceptance claim.

## Package and publish

Mirror the existing release layout so consumers can swap archives:

```
xEdit.exe            # 64-bit build; xEdit.exe and xEdit64.exe are byte-identical copies
xEdit64.exe
Edit Scripts/
Themes/
LICENSE.txt
README.package.txt   # state what was built, from which commit, and how it was verified
```

Zip those, then:

```
sha256sum xEdit.4.1.6-automation.<n>.zip xEdit64.exe > SHA256SUMS.txt
gh release create v4.1.6-automation.<n> --repo ejams1/xEdit-llm \
  --target <commit> --title "4.1.6 automation r<n>" \
  --notes-file notes.md xEdit.4.1.6-automation.<n>.zip xEdit64.exe SHA256SUMS.txt
```

The release notes must say plainly whether the assets are a fork-local build or an upstream build of
identical source — consumers pin hashes, so the provenance line is part of the artifact.
