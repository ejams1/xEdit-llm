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

So: if `git rev-list --count upstream/automation-4.1.6..HEAD` is `0`, there is nothing to build that is not
already released. Rebuild only when the fork has commits upstream does not.

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

   A command-line equivalent (untested on this machine; Delphi must be on the path via its `rsvars.bat`):

   ```
   msbuild xEdit.dproj /p:Config=LiteDebug /p:Platform=Win64 /t:Build
   ```

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
2. **Daemon smoke test.** The fork's automation mode is the part the pipeline actually depends on: launch
   the new executable as `xEdit.exe -FO4 -AutomationPipe:<pipe-name>`, then drive it through the xEdit MCP
   and confirm it reports the expected automation contract version (0.23 for r9) and answers `xedit_health`.
   Finish with an ordinary record read against a real plugin.
3. Only if both pass, treat the build as a valid replacement.

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
