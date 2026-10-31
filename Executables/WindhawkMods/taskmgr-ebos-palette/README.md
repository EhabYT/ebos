# Task Manager EBOS palette (Windhawk mod)

Local Windhawk mod that keeps the acrylic Task Manager shell while restoring
the EBOS classic palette in its process list.

## Why this exists

`translucent-windows` renders the acrylic Task Manager shell when

```
RuledPrograms[1].target                       = Taskmgr.exe
RuledPrograms[1].RenderingMod.ThemeBackground = 1
```

The same custom-rendering path installs `GetSysColor`/`GetSysColorBrush` hooks
that return `RGB(0, 0, 0)` for `COLOR_WINDOW` and `COLOR_BTNFACE`. Task
Manager's process list is a classic `SysListView32`; it fills its background
with `GetSysColorBrush(COLOR_WINDOW)`, so it turns solid black inside the glass
window.

`ThemeBackground=0` avoids the black list but also disables the shell
rendering, leaving an opaque dark window. `RenderingMod.Syscolors=1` is not an
option either: it calls `SetSysColors` system-wide with the same black values
and would override the EBOS palette for every process.

This mod is injected into `taskmgr.exe` only. It returns the same 31 colors as
`Executables/ebos-dark.theme` (deep navy `Window=10 24 42`, white text, EBOS
blue highlight, light-gray `GrayText`) for the classic color APIs. The global
mod still paints the acrylic shell.

## Hook order

The mod intentionally does **not** register hooks in `Wh_ModInit`.

All `Wh_ModInit` callbacks run before any `Wh_ModAfterInit` callback. This mod
registers `GetSysColor` and `GetSysColorBrush` in `Wh_ModAfterInit` and then
calls `Wh_ApplyHookOperations`, so its detours are attached after
`translucent-windows` has attached its own. Windhawk's MinHook build chains
hooks on the same target; the hook attached last runs first. The result is:

```
user32!GetSysColor -> taskmgr-ebos-palette -> translucent-windows -> user32
```

The palette hook returns a color directly and never calls the next hook for a
known `COLOR_*` index, so the black hardcode cannot win. This is also why the
mod does not depend on the `std::unordered_map` load order in the Windhawk
engine.

`InternalWhModPtr` and the Itanium-style entry points (`_Z10Wh_ModInitv`,
`_Z15Wh_ModAfterInitv`, `_Z12Wh_ModUninitv`) are exported explicitly because
the DLL is built with MSVC. MSVC mangles C++ names differently, so the source
aliases the expected names with `#pragma comment(linker, "/export:...")`.

## Files

| File | Purpose |
|---|---|
| `taskmgr-ebos-palette.wh.cpp` | Mod source and the EBOS palette table |
| `1.0_64.dll` | Precompiled 64-bit mod shipped with the playbook |
| `build.ps1` | Rebuilds the DLL with MSVC and verifies its SHA-256 |

## Build

Requirements:

- Visual Studio 2022 with the C++ desktop workload (MSVC 14.44 was used for
  the shipped DLL)
- WindhawkCLI installed, providing `Engine\<version>\64\windhawk.lib`

From this folder:

```powershell
.\build.ps1
```

The script auto-detects `vcvars64.bat` and `windhawk.lib`. To use explicit
paths:

```powershell
.\build.ps1 `
  -VsDevCmd 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat' `
  -WindhawkLib 'C:\Program Files\WindhawkCLI\Engine\1.7.3\64\windhawk.lib'
```

The DLL is linked with `/MT` (static CRT) and `/Brepro` (deterministic
output), so rebuilding with the same toolchain produces the same SHA-256. The
build fails if the hash differs from the installer pin; use `-SkipHashCheck`
only when intentionally changing the source or compiler.

After an intentional rebuild, update **both**:

1. `$expectedSha256` in `build.ps1`
2. `$ExpectedTaskMgrPaletteSha256` in
   `..\..\Install-WindhawkTransparentUI.ps1`

The installer refuses to install a DLL whose hash does not match.

## Installation

`Executables/Install-WindhawkTransparentUI.ps1` does this automatically, in
this order:

1. Verifies `1.0_64.dll` against the pinned SHA-256.
2. `whcli install-local <this folder> --disabled`
3. Writes `Include = taskmgr.exe` to the mod's registry key.
4. `whcli enable taskmgr-ebos-palette`
5. Verifies that the mod is installed, enabled, and scoped to `taskmgr.exe`.

The mod is installed disabled and scoped before it is enabled, so the first
injection is already limited to Task Manager.

## Testing

Restart Task Manager after installation (it is single-instance). Then, from an
**elevated** prompt:

```powershell
whcli mod-status taskmgr-ebos-palette
```

The elevated Task Manager process must be listed. An unelevated `whcli` cannot
see an elevated Task Manager even when the mod is loaded.

Expected result:

- The window keeps the acrylic/translucent shell.
- The process list background is deep navy (`#0A182A`, not black).
- Process names and values are white and readable.
- The search field and selection highlight use the EBOS palette.

If the list is still black, check the Windhawk mod log for this mod: a failed
`InternalWh_SetFunctionHook` or `InternalWh_ApplyHookOperations` call means the
hook was not attached, and the global mod's black hardcode is still winning.
