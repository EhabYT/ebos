// ==WindhawkMod==
// @id              taskmgr-ebos-palette
// @name            Task Manager EBOS palette
// @description     Keeps the transparent Task Manager shell but restores the EBOS navy palette in its classic process list
// @version         1.0
// @author          EBOS
// @include         taskmgr.exe
// @compilerOptions -luser32 -lgdi32
// ==/WindhawkMod==

// ==WindhawkModReadme==
/*
The global `translucent-windows` mod replaces the classic system colors with
hard-coded black values whenever its custom theme rendering is enabled. Task
Manager's process list is a classic `SysListView32`; it fills its background
with `GetSysColorBrush(COLOR_WINDOW)`, so it turns solid black even though the
rest of the window is acrylic.

This mod is loaded into `Taskmgr.exe` only. It registers its `GetSysColor` and
`GetSysColorBrush` hooks from `Wh_ModAfterInit`, after every other Windhawk mod
has registered its own hooks, then applies them. The result is the EBOS navy
palette with white text while the global mod still provides the acrylic shell.

The palette matches `Executables/ebos-dark.theme` and
`Executables/restore-personalization.ps1`.
*/
// ==/WindhawkModReadme==

#include <windows.h>
#include <cstdarg>

// Windhawk's engine writes its LoadedMod pointer into this exported variable
// before calling Wh_ModInit. The mod shim (windhawk.dll) uses it for the
// InternalWh_* API calls below.
extern "C" __declspec(dllexport) void* InternalWhModPtr = nullptr;

extern "C" {
__declspec(dllimport) BOOL InternalWh_IsLogEnabled(void* mod);
__declspec(dllimport) void InternalWh_Log(void* mod, PCWSTR format, va_list args);
__declspec(dllimport) BOOL InternalWh_SetFunctionHook(void* mod,
                                                      void* targetFunction,
                                                      void* hookFunction,
                                                      void** originalFunction);
__declspec(dllimport) BOOL InternalWh_ApplyHookOperations(void* mod);
}

static void Log(PCWSTR format, ...) {
    if (!InternalWh_IsLogEnabled(InternalWhModPtr)) {
        return;
    }
    va_list args;
    va_start(args, format);
    InternalWh_Log(InternalWhModPtr, format, args);
    va_end(args);
}

using GetSysColor_t = DWORD(WINAPI*)(int);
using GetSysColorBrush_t = HBRUSH(WINAPI*)(int);

static GetSysColor_t GetSysColor_Original;
static GetSysColorBrush_t GetSysColorBrush_Original;

// Indexed by the classic COLOR_* constants (0..30). Values match
// Executables/ebos-dark.theme, including ButtonAlternateFace at index 25.
static const COLORREF kEbosPalette[31] = {
    RGB(12, 28, 48),    // 0  COLOR_SCROLLBAR
    RGB(6, 16, 30),     // 1  COLOR_BACKGROUND
    RGB(8, 24, 44),     // 2  COLOR_ACTIVECAPTION
    RGB(6, 16, 30),     // 3  COLOR_INACTIVECAPTION
    RGB(10, 20, 34),    // 4  COLOR_MENU
    RGB(10, 24, 42),    // 5  COLOR_WINDOW
    RGB(64, 96, 128),   // 6  COLOR_WINDOWFRAME
    RGB(255, 255, 255), // 7  COLOR_MENUTEXT
    RGB(255, 255, 255), // 8  COLOR_WINDOWTEXT
    RGB(255, 255, 255), // 9  COLOR_CAPTIONTEXT
    RGB(36, 72, 112),   // 10 COLOR_ACTIVEBORDER
    RGB(16, 34, 56),    // 11 COLOR_INACTIVEBORDER
    RGB(6, 14, 26),     // 12 COLOR_APPWORKSPACE
    RGB(0, 122, 255),   // 13 COLOR_HIGHLIGHT
    RGB(255, 255, 255), // 14 COLOR_HIGHLIGHTTEXT
    RGB(10, 24, 42),    // 15 COLOR_BTNFACE
    RGB(4, 10, 18),     // 16 COLOR_BTNSHADOW
    RGB(168, 184, 204), // 17 COLOR_GRAYTEXT
    RGB(255, 255, 255), // 18 COLOR_BTNTEXT
    RGB(200, 214, 230), // 19 COLOR_INACTIVECAPTIONTEXT
    RGB(48, 80, 116),   // 20 COLOR_BTNHIGHLIGHT
    RGB(2, 6, 12),      // 21 COLOR_3DDKSHADOW
    RGB(16, 34, 56),    // 22 COLOR_3DLIGHT
    RGB(255, 255, 255), // 23 COLOR_INFOTEXT
    RGB(12, 28, 48),    // 24 COLOR_INFOBK
    RGB(10, 24, 42),    // 25 COLOR_BTNALTFACE
    RGB(95, 200, 255),  // 26 COLOR_HOTLIGHT
    RGB(8, 24, 44),     // 27 COLOR_GRADIENTACTIVECAPTION
    RGB(6, 16, 30),     // 28 COLOR_GRADIENTINACTIVECAPTION
    RGB(0, 122, 255),   // 29 COLOR_MENUHILIGHT
    RGB(6, 16, 30),     // 30 COLOR_MENUBAR
};

static HBRUSH g_paletteBrushes[31] = {};

static DWORD WINAPI HookedGetSysColor(int nIndex) {
    if (nIndex >= 0 && nIndex < ARRAYSIZE(kEbosPalette)) {
        return kEbosPalette[nIndex];
    }
    return GetSysColor_Original(nIndex);
}

static HBRUSH WINAPI HookedGetSysColorBrush(int nIndex) {
    if (nIndex >= 0 && nIndex < ARRAYSIZE(kEbosPalette)) {
        HBRUSH brush = g_paletteBrushes[nIndex];
        if (!brush) {
            HBRUSH created = CreateSolidBrush(kEbosPalette[nIndex]);
            if (!created) {
                return GetSysColorBrush_Original(nIndex);
            }
            HBRUSH previous = static_cast<HBRUSH>(
                InterlockedCompareExchangePointer(
                    reinterpret_cast<PVOID volatile*>(&g_paletteBrushes[nIndex]),
                    created, nullptr));
            if (previous) {
                // Another thread won the race; use its brush and drop ours.
                DeleteObject(created);
                brush = previous;
            } else {
                brush = created;
            }
        }
        return brush;
    }
    return GetSysColorBrush_Original(nIndex);
}

extern "C" __declspec(dllexport) BOOL __cdecl Wh_ModInit() {
    // No hooks here on purpose. They are installed from Wh_ModAfterInit so
    // that they are the outermost hooks even if this mod happens to load
    // before translucent-windows.
    return TRUE;
}

extern "C" __declspec(dllexport) void __cdecl Wh_ModAfterInit() {
    BOOL colorHook = InternalWh_SetFunctionHook(
        InternalWhModPtr, reinterpret_cast<void*>(GetSysColor),
        reinterpret_cast<void*>(HookedGetSysColor),
        reinterpret_cast<void**>(&GetSysColor_Original));
    if (!colorHook) {
        Log(L"taskmgr-ebos-palette: GetSysColor hook registration failed");
    }

    BOOL brushHook = InternalWh_SetFunctionHook(
        InternalWhModPtr, reinterpret_cast<void*>(GetSysColorBrush),
        reinterpret_cast<void*>(HookedGetSysColorBrush),
        reinterpret_cast<void**>(&GetSysColorBrush_Original));
    if (!brushHook) {
        Log(L"taskmgr-ebos-palette: GetSysColorBrush hook registration failed");
    }

    if (colorHook || brushHook) {
        BOOL applied = InternalWh_ApplyHookOperations(InternalWhModPtr);
        Log(L"taskmgr-ebos-palette: hooks registered (color=%d, brush=%d), apply=%d",
            colorHook, brushHook, applied);
    }
}

extern "C" __declspec(dllexport) void __cdecl Wh_ModUninit() {}

// The Windhawk engine looks these up by the names clang would emit. MSVC
// mangles C++ differently, so map the Itanium names to the C functions above.
#pragma comment(linker, "/export:_Z10Wh_ModInitv=Wh_ModInit")
#pragma comment(linker, "/export:_Z15Wh_ModAfterInitv=Wh_ModAfterInit")
#pragma comment(linker, "/export:_Z12Wh_ModUninitv=Wh_ModUninit")
