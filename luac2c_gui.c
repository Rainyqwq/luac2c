/* luac2c_gui.c -- luac2c 的 Windows x64 原生客户端
**
** 一键流水线:  luac.exe  ->  luac2c.exe  ->  gcc  ->  运行并与 lua.exe 逐字节比对
**
**   gcc luac2c_gui.c -mwindows -O2 -o luac2c_gui.exe -lcomdlg32 -lshell32
**
** 工具与库路径默认取本程序所在目录（luac.exe / luac2c.exe / lua.exe / lua-5.5.1/...），
** gcc 依次尝试  环境变量 GCC -> 本目录 -> 系统 PATH（不写死任何本机路径）；
** 都可以在同目录的 luac2c_gui.ini 里按 [paths] 覆盖。
*/
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* MinGW 头文件在低版本 WINVER 下不导出这些宽字符类名，缺了就自己补 */
#ifndef WC_STATICW
#define WC_STATICW  L"Static"
#endif
#ifndef WC_EDITW
#define WC_EDITW    L"Edit"
#endif
#ifndef WC_BUTTONW
#define WC_BUTTONW  L"Button"
#endif

/* ------------------------------------------------------------------ IDs */
#define IDC_SRC        101
#define IDC_BROWSE     102
#define IDC_RB_DYN     110
#define IDC_RB_SEED    111
#define IDC_RB_STATIC  112
#define IDC_SEED       113
#define IDC_NOPOOL     120
#define IDC_ANNOTATE   121
#define IDC_TOOLS      122
#define IDC_RUN        130
#define IDC_TRANSLATE  131
#define IDC_REBUILD    132
#define IDC_OPEN       133
#define IDC_CLEAR      134
#define IDC_STATUS     140
#define IDC_LOG        141

#define WM_APP_LOG     (WM_APP + 1)   /* lParam: heap wchar_t*, receiver frees */
#define WM_APP_STATUS  (WM_APP + 2)   /* lParam: heap wchar_t*, receiver frees */
#define WM_APP_DONE    (WM_APP + 3)   /* wParam: 1 = 全部通过 */

/* ------------------------------------------------------------------ state */
static HINSTANCE g_hInst;
static HWND g_hwnd, g_log, g_status;
static HFONT g_font, g_mono;
static CRITICAL_SECTION g_cs;
static volatile LONG g_busy = 0;

static wchar_t g_root[MAX_PATH] = L".";
static wchar_t g_ini[MAX_PATH] = L"";
static wchar_t g_luac[MAX_PATH], g_l2c[MAX_PATH], g_lua[MAX_PATH], g_gcc[MAX_PATH];
static wchar_t g_inc1[MAX_PATH], g_inc2[MAX_PATH], g_lib[MAX_PATH];

struct job {
    wchar_t src[MAX_PATH];
    int mode;            /* 0 = 多样化, 1 = 指定种子, 2 = --static */
    unsigned long seed;
    int nopool, annot;
    int full;            /* 1 = 完整流水线, 0 = 仅翻译 */
};

/* ------------------------------------------------------------------ util */
static int file_exists(const wchar_t *p) {
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static void joinpath(wchar_t *dst, size_t n, const wchar_t *dir, const wchar_t *name) {
    _snwprintf(dst, n, L"%ls\\%ls", dir, name);
    dst[n - 1] = 0;
}

/* 把一段多字节输出（gcc 可能给 UTF-8，也可能给本地码页）转成宽字符 */
static wchar_t *mb_to_wide(const char *s, int n) {
    int w = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, n, NULL, 0);
    if (w <= 0) w = MultiByteToWideChar(CP_ACP, 0, s, n, NULL, 0);
    if (w <= 0) return NULL;
    wchar_t *d = (wchar_t *)malloc((size_t)(w + 1) * sizeof(wchar_t));
    if (!d) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, n, d, w) <= 0)
        MultiByteToWideChar(CP_ACP, 0, s, n, d, w);
    d[w] = 0;
    return d;
}

static void post_log(const wchar_t *fmt, ...) {
    wchar_t buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 4095, fmt, ap);
    va_end(ap);
    buf[4095] = 0;
    size_t n = wcslen(buf);
    wchar_t *heap = (wchar_t *)malloc((n + 1) * sizeof(wchar_t));
    if (!heap) return;
    wcscpy(heap, buf);
    PostMessageW(g_hwnd, WM_APP_LOG, 0, (LPARAM)heap);
}

static void post_status(const wchar_t *fmt, ...) {
    wchar_t buf[512];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(buf, 511, fmt, ap);
    va_end(ap);
    buf[511] = 0;
    wchar_t *heap = (wchar_t *)malloc((wcslen(buf) + 1) * sizeof(wchar_t));
    if (!heap) return;
    wcscpy(heap, buf);
    PostMessageW(g_hwnd, WM_APP_STATUS, 0, (LPARAM)heap);
}

/* ------------------------------------------------------------------ run */
/* 运行一行命令，合并 stdout+stderr；返回 0 = 创建进程失败 */
static int run_capture(const wchar_t *cmd, const wchar_t *cwd,
                       wchar_t **out, DWORD *exitcode) {
    *out = NULL;
    *exitcode = (DWORD)-1;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof sa; sa.bInheritHandle = TRUE; sa.lpSecurityDescriptor = NULL;
    HANDLE rd = NULL, wr = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 0)) return 0;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = wr;
    si.hStdError  = wr;

    wchar_t *mutable_cmd = _wcsdup(cmd);
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof pi);
    BOOL ok = CreateProcessW(NULL, mutable_cmd, NULL, NULL, TRUE,
                             CREATE_NO_WINDOW, NULL, cwd, &si, &pi);
    free(mutable_cmd);
    CloseHandle(wr);                     /* 先关写端，读到 EOF 才会返回 */
    if (!ok) { CloseHandle(rd); return 0; }

    size_t cap = 8192, len = 0;
    char *acc = (char *)malloc(cap);
    if (acc) {
        for (;;) {
            if (len + 4096 > cap) { cap *= 2; char *nb = (char *)realloc(acc, cap); if (!nb) break; acc = nb; }
            DWORD got = 0;
            if (!ReadFile(rd, acc + len, 4096, &got, NULL) || got == 0) break;
            len += got;
        }
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, exitcode);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(rd);

    if (acc) {
        *out = mb_to_wide(acc, (int)len);
        free(acc);
    }
    return 1;
}

/* 供子进程使用的命令行缓冲必须可写 */
static wchar_t *qarg(const wchar_t *p) {          /* 给路径加引号 */
    static wchar_t slot[4][MAX_PATH * 2];
    static int turn = 0;
    wchar_t *b = slot[turn = (turn + 1) & 3];
    _snwprintf(b, MAX_PATH * 2 - 1, L"\"%ls\"", p);
    b[MAX_PATH * 2 - 1] = 0;
    return b;
}

/* ------------------------------------------------------------------ tools */
static void find_tools(void) {
    wchar_t def[MAX_PATH];
    wchar_t *envgcc;

    /* gcc: 环境变量 GCC -> 本目录 -> PATH */
    envgcc = _wgetenv(L"GCC");
    if (envgcc && *envgcc) wcscpy(g_gcc, envgcc);
    else {
        joinpath(def, MAX_PATH, g_root, L"gcc.exe");
        wcscpy(g_gcc, def);
    }
    if (!file_exists(g_gcc)) {
        wchar_t *pathdup = _wcsdup(_wgetenv(L"PATH") ? _wgetenv(L"PATH") : L"");
        if (pathdup) {
            wchar_t *ctx = NULL;
            wchar_t *tok = wcstok(pathdup, L";", &ctx);
            while (tok && !file_exists(g_gcc)) {
                joinpath(def, MAX_PATH, tok, L"gcc.exe");
                if (file_exists(def)) wcscpy(g_gcc, def);
                tok = wcstok(NULL, L";", &ctx);
            }
            free(pathdup);
        }
    }

    joinpath(g_luac, MAX_PATH, g_root, L"luac.exe");
    joinpath(g_l2c,  MAX_PATH, g_root, L"luac2c.exe");
    joinpath(g_lua,  MAX_PATH, g_root, L"lua.exe");
    joinpath(g_inc1, MAX_PATH, g_root, L"lua-5.5.1\\src");
    joinpath(g_inc2, MAX_PATH, g_root, L"lua5.5-include");
    joinpath(g_lib,  MAX_PATH, g_root, L"lua-5.5.1\\build\\liblua.a");

    /* luac2c_gui.ini 的 [paths] 段可覆盖 */
    static const struct { const wchar_t *key; wchar_t *dst; } tbl[] = {
        { L"luac", g_luac }, { L"luac2c", g_l2c }, { L"lua", g_lua },
        { L"gcc", g_gcc }, { L"inc1", g_inc1 }, { L"inc2", g_inc2 },
        { L"lib", g_lib },
    };
    wchar_t buf[MAX_PATH];
    for (size_t i = 0; i < sizeof tbl / sizeof tbl[0]; i++) {
        GetPrivateProfileStringW(L"paths", tbl[i].key, tbl[i].dst, buf, MAX_PATH, g_ini);
        wcscpy(tbl[i].dst, buf);
    }
}

/* ------------------------------------------------------------------ job */
static DWORD WINAPI worker(LPVOID arg) {
    struct job *j = (struct job *)arg;

    wchar_t drive[_MAX_DRIVE], dir[_MAX_DIR], base[_MAX_FNAME];
    _wsplitpath(j->src, drive, dir, base, NULL);
    wchar_t outdir[MAX_PATH];
    _snwprintf(outdir, MAX_PATH, L"%ls%ls", drive, dir);
    outdir[MAX_PATH - 1] = 0;

    wchar_t p_luac[MAX_PATH], p_c[MAX_PATH], p_exe[MAX_PATH];
    joinpath(p_luac, MAX_PATH, outdir, base); wcscat(p_luac, L".luac");
    joinpath(p_c,    MAX_PATH, outdir, base); wcscat(p_c,    L"_out.c");
    joinpath(p_exe,  MAX_PATH, outdir, base); wcscat(p_exe,  L"_out.exe");

    wchar_t cmd[4096], opt[128];
    wchar_t *o = NULL;
    DWORD code = 0;

    /* ---- 1. lua -> luac ---- */
    post_log(L"[1/5] luac  编译字节码");
    _snwprintf(cmd, 4096, L"%ls -o %ls %ls", qarg(g_luac), qarg(p_luac), qarg(j->src));
    cmd[4095] = 0;
    if (!run_capture(cmd, outdir, &o, &code)) {
        post_log(L"      ✗ 无法启动 %ls（检查 [paths] luac）", g_luac);
        goto done_fail;
    }
    if (o && *o) post_log(L"      %ls", o);
    free(o); o = NULL;
    if (code != 0) { post_log(L"      ✗ luac 退出码 %lu", (unsigned long)code); goto done_fail; }
    post_log(L"      → %ls", p_luac);

    /* ---- 2. luac2c -> C ---- */
    post_log(L"[2/5] luac2c  翻译为 C");
    opt[0] = 0;
    if (j->mode == 1) _snwprintf(opt, 128, L"--seed %lu", (unsigned long)j->seed);
    if (j->mode == 2) _snwprintf(opt, 128, L"--static");
    opt[127] = 0;
    _snwprintf(cmd, 4096, L"%ls %ls -o %ls %ls%ls%ls",
               qarg(g_l2c), qarg(p_luac), qarg(p_c), opt,
               j->nopool ? L" --no-pool" : L"", j->annot ? L" --annotate" : L"");
    cmd[4095] = 0;
    if (!run_capture(cmd, outdir, &o, &code)) {
        post_log(L"      ✗ 无法启动 %ls（检查 [paths] luac2c）", g_l2c);
        goto done_fail;
    }
    if (o && *o) post_log(L"      %ls", o);
    free(o); o = NULL;
    if (code != 0) { post_log(L"      ✗ luac2c 退出码 %lu", (unsigned long)code); goto done_fail; }
    post_log(L"      → %ls", p_c);
    if (!j->full) { post_status(L"翻译完成：%ls", p_c); goto done_ok; }

    /* ---- 3. gcc ---- */
    post_log(L"[3/5] gcc  编译链接");
    _snwprintf(cmd, 4096,
               L"%ls %ls -I %ls -I %ls -std=c99 -w -O0 -o %ls %ls -lm",
               qarg(g_gcc), qarg(p_c), qarg(g_inc1), qarg(g_inc2),
               qarg(p_exe), qarg(g_lib));
    cmd[4095] = 0;
    if (!run_capture(cmd, outdir, &o, &code)) {
        post_log(L"      ✗ 无法启动 %ls（检查 [paths] gcc）", g_gcc);
        goto done_fail;
    }
    if (o && *o) post_log(L"      %ls", o);
    free(o); o = NULL;
    if (code != 0) { post_log(L"      ✗ gcc 退出码 %lu", (unsigned long)code); goto done_fail; }
    post_log(L"      → %ls", p_exe);

    /* ---- 4. 运行生成物 ---- */
    post_log(L"[4/5] 运行生成物");
    if (!run_capture(qarg(p_exe), outdir, &o, &code)) {
        post_log(L"      ✗ 无法启动生成物");
        goto done_fail;
    }
    size_t len_out = o ? wcslen(o) : 0;
    wchar_t *gen_out = o;
    DWORD gen_code = code;

    /* ---- 5. 与 lua.exe 比对 ---- */
    post_log(L"[5/5] 与 lua.exe 输出比对");
    wchar_t *ref_out = NULL;
    DWORD ref_code = 0;
    _snwprintf(cmd, 4096, L"%ls %ls", qarg(g_lua), qarg(j->src));
    cmd[4095] = 0;
    if (!run_capture(cmd, outdir, &ref_out, &ref_code)) {
        post_log(L"      ✗ 无法启动 %ls（检查 [paths] lua）", g_lua);
        free(gen_out); goto done_fail;
    }

    /* 去掉尾部空白后再比，和 runall.ps1 一致 */
    while (len_out && (gen_out[len_out-1]==L'\n' || gen_out[len_out-1]==L'\r' ||
                       gen_out[len_out-1]==L' '  || gen_out[len_out-1]==L'\t'))
        gen_out[--len_out] = 0;
    size_t len_ref = ref_out ? wcslen(ref_out) : 0;
    while (len_ref && (ref_out[len_ref-1]==L'\n' || ref_out[len_ref-1]==L'\r' ||
                       ref_out[len_ref-1]==L' '  || ref_out[len_ref-1]==L'\t'))
        ref_out[--len_ref] = 0;

    int same = (len_out == len_ref) && (memcmp(gen_out, ref_out,
                 len_out * sizeof(wchar_t)) == 0) && (gen_code == ref_code);
    if (gen_out && *gen_out) post_log(L"      生成物> %ls", gen_out);
    if (ref_out && *ref_out) post_log(L"      lua.exe> %ls", ref_out);
    free(gen_out); free(ref_out);

    if (same) {
        post_log(L"      ✓ 输出一致，退出码一致 (%lu)", (unsigned long)gen_code);
        post_status(L"通过：%ls", j->src);
        PostMessageW(g_hwnd, WM_APP_DONE, 1, 0);
    } else {
        post_log(L"      ✗ 不一致（exit %lu vs %lu）",
                 (unsigned long)gen_code, (unsigned long)ref_code);
        post_status(L"不一致：%ls", j->src);
        PostMessageW(g_hwnd, WM_APP_DONE, 0, 0);
    }
    free(j);
    InterlockedExchange(&g_busy, 0);
    return 0;

done_ok:
    PostMessageW(g_hwnd, WM_APP_DONE, 1, 0);
    free(j);
    InterlockedExchange(&g_busy, 0);
    return 0;

done_fail:
    free(o);
    post_status(L"失败：%ls（见日志）", j->src);
    PostMessageW(g_hwnd, WM_APP_DONE, 0, 0);
    free(j);
    InterlockedExchange(&g_busy, 0);
    return 0;
}

/* 重建 luac2c.exe 的独立线程 */
static DWORD WINAPI rebuild(LPVOID arg) {
    (void)arg;
    post_log(L"[重建] gcc luac2c.c -O2 -o luac2c.exe");
    wchar_t cmd[4096];
    _snwprintf(cmd, 4096, L"%ls \"%ls\\luac2c.c\" -O2 -o %ls -lm",
               qarg(g_gcc), g_root, qarg(g_l2c));
    cmd[4095] = 0;
    wchar_t *o = NULL; DWORD code = 0;
    if (!run_capture(cmd, g_root, &o, &code)) {
        post_log(L"      ✗ 无法启动 gcc"); goto rd;
    }
    if (o && *o) post_log(L"      %ls", o);
    free(o);
    if (code == 0) post_log(L"      ✓ luac2c.exe 已重建");
    else           post_log(L"      ✗ gcc 退出码 %lu", (unsigned long)code);
rd:
    post_status(code == 0 ? L"luac2c.exe 已重建" : L"重建失败");
    PostMessageW(g_hwnd, WM_APP_DONE, code == 0, 0);
    InterlockedExchange(&g_busy, 0);
    return 0;
}

/* ------------------------------------------------------------------ UI */
static void log_append(const wchar_t *s) {
    size_t len = GetWindowTextLengthW(g_log);
    SendMessageW(g_log, EM_SETSEL, (WPARAM)len, (LPARAM)len);
    SendMessageW(g_log, EM_REPLACESEL, FALSE, (LPARAM)s);
    SendMessageW(g_log, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
    SendMessageW(g_log, EM_SCROLLCARET, 0, 0);
}

static void set_ui_busy(HWND hwnd, BOOL busy) {
    static const int ids[] = { IDC_RUN, IDC_TRANSLATE, IDC_REBUILD, IDC_BROWSE,
                               IDC_SEED, IDC_SRC, IDC_RB_DYN, IDC_RB_SEED,
                               IDC_RB_STATIC, IDC_NOPOOL, IDC_ANNOTATE };
    for (size_t i = 0; i < sizeof ids / sizeof ids[0]; i++)
        EnableWindow(GetDlgItem(hwnd, ids[i]), !busy);
}

static void pick_file(HWND hwnd) {
    wchar_t file[MAX_PATH];
    file[0] = 0;
    OPENFILENAMEW ofn;
    memset(&ofn, 0, sizeof ofn);
    ofn.lStructSize = sizeof ofn;
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter = L"Lua 源文件\0*.lua\0Lua 字节码\0*.luac\0所有文件\0*.*\0";
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_HIDEREADONLY;
    if (GetOpenFileNameW(&ofn)) {
        wchar_t full[MAX_PATH];
        GetFullPathNameW(file, MAX_PATH, full, NULL);
        SetWindowTextW(GetDlgItem(hwnd, IDC_SRC), full);
    }
}

static void open_outdir(HWND hwnd) {
    wchar_t src[MAX_PATH];
    GetWindowTextW(GetDlgItem(hwnd, IDC_SRC), src, MAX_PATH);
    wchar_t drive[_MAX_DRIVE], dir[_MAX_DIR];
    _wsplitpath(src, drive, dir, NULL, NULL);
    wchar_t outdir[MAX_PATH];
    _snwprintf(outdir, MAX_PATH, L"%ls%ls", drive, dir);
    outdir[MAX_PATH - 1] = 0;
    if (!outdir[0]) wcscpy(outdir, g_root);
    ShellExecuteW(hwnd, L"open", outdir, NULL, NULL, SW_SHOWNORMAL);
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        HFONT f = g_font;
        struct { const wchar_t *txt; int id, x, y, w, h; const wchar_t *cls; DWORD st; } c[] = {
            { L"Lua 源文件", -1,   16,  21,  78, 20, WC_STATICW, 0 },
            { L"", IDC_SRC,      100, 16,  556, 24, WC_EDITW, WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL },
            { L"浏览…", IDC_BROWSE, 668, 15, 76, 26, WC_BUTTONW, WS_VISIBLE },
            { L"翻译模式", -1,   16,  55,  80, 20, WC_STATICW, 0 },
            { L"默认多样化", IDC_RB_DYN,   100, 54, 96, 20, WC_BUTTONW, WS_VISIBLE | BS_AUTORADIOBUTTON | WS_GROUP },
            { L"指定种子", IDC_RB_SEED,  202, 54, 78, 20, WC_BUTTONW, WS_VISIBLE | BS_AUTORADIOBUTTON },
            { L"--static", IDC_RB_STATIC, 286, 54, 72, 20, WC_BUTTONW, WS_VISIBLE | BS_AUTORADIOBUTTON },
            { L"", IDC_SEED,     364, 52, 60, 22, WC_EDITW, WS_VISIBLE | WS_BORDER | ES_NUMBER },
            { L"--no-pool", IDC_NOPOOL,   440, 54, 90, 20, WC_BUTTONW, WS_VISIBLE | BS_AUTOCHECKBOX },
            { L"--annotate", IDC_ANNOTATE, 540, 54, 100, 20, WC_BUTTONW, WS_VISIBLE | BS_AUTOCHECKBOX },
            { L"", IDC_TOOLS,    100, 78, 652, 34, WC_STATICW, 0 },
            { L"一键流水线", IDC_RUN,     16, 124, 110, 30, WC_BUTTONW, WS_VISIBLE },
            { L"仅翻译 C", IDC_TRANSLATE,134, 124, 90, 30, WC_BUTTONW, WS_VISIBLE },
            { L"重建 luac2c", IDC_REBUILD,232, 124, 100, 30, WC_BUTTONW, WS_VISIBLE },
            { L"打开输出目录", IDC_OPEN,  340, 124, 110, 30, WC_BUTTONW, WS_VISIBLE },
            { L"清空日志", IDC_CLEAR,   458, 124, 80, 30, WC_BUTTONW, WS_VISIBLE },
            { L"就绪", IDC_STATUS,   16, 162, 828, 20, WC_STATICW, 0 },
            { L"", IDC_LOG,      16, 190, 828, 440, WC_EDITW, WS_VISIBLE | WS_BORDER | WS_VSCROLL | WS_HSCROLL |
                                       ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL },
        };
        for (size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
            HWND h = CreateWindowExW(0, c[i].cls, c[i].txt,
                    WS_CHILD | c[i].st |
                    (wcscmp(c[i].cls, WC_BUTTONW) == 0 ? WS_TABSTOP : 0) |
                    (wcscmp(c[i].cls, WC_STATICW) == 0 ? WS_VISIBLE : 0),
                    c[i].x, c[i].y, c[i].w, c[i].h, hwnd,
                    (HMENU)(INT_PTR)c[i].id, g_hInst, NULL);
            SendMessageW(h, WM_SETFONT, (WPARAM)f, TRUE);
        }
        SendMessageW(g_log = GetDlgItem(hwnd, IDC_LOG), WM_SETFONT, (WPARAM)g_mono, TRUE);
        SendMessageW(GetDlgItem(hwnd, IDC_RB_DYN), BM_SETCHECK, BST_CHECKED, 0);
        SetWindowTextW(GetDlgItem(hwnd, IDC_TOOLS),
            L"(工具路径见 luac2c_gui.ini 的 [paths] 段，可覆盖)");
        DragAcceptFiles(hwnd, TRUE);
        return 0;
    }
    case WM_DROPFILES: {
        wchar_t f[MAX_PATH];
        HDROP d = (HDROP)wp;
        if (DragQueryFileW(d, 0, f, MAX_PATH)) {
            wchar_t full[MAX_PATH];
            GetFullPathNameW(f, MAX_PATH, full, NULL);
            SetWindowTextW(GetDlgItem(hwnd, IDC_SRC), full);
        }
        DragFinish(d);
        return 0;
    }
    case WM_APP_LOG:
        log_append((const wchar_t *)lp);
        free((void *)lp);
        return 0;
    case WM_APP_STATUS: {
        wchar_t *s = (wchar_t *)lp;
        SetWindowTextW(g_status = GetDlgItem(hwnd, IDC_STATUS), s);
        free((void *)s);
        return 0;
    }
    case WM_APP_DONE:
        set_ui_busy(hwnd, FALSE);
        return 0;
    case WM_COMMAND: {
        int id = LOWORD(wp);
        if (id == IDC_BROWSE) { pick_file(hwnd); return 0; }
        if (id == IDC_CLEAR)  { SetWindowTextW(GetDlgItem(hwnd, IDC_LOG), L""); return 0; }
        if (id == IDC_OPEN)   { open_outdir(hwnd); return 0; }
        if (id == IDC_RUN || id == IDC_TRANSLATE || id == IDC_REBUILD) {
            if (InterlockedCompareExchange(&g_busy, 1, 0) != 0) return 0;
            if (id == IDC_REBUILD) {
                set_ui_busy(hwnd, TRUE);
                CloseHandle(CreateThread(NULL, 0, rebuild, NULL, 0, NULL));
                return 0;
            }
            wchar_t src[MAX_PATH];
            GetWindowTextW(GetDlgItem(hwnd, IDC_SRC), src, MAX_PATH);
            if (!src[0]) {
                MessageBoxW(hwnd, L"请先选择 .lua 源文件（或直接把文件拖进窗口）",
                            L"luac2c", MB_ICONINFORMATION);
                InterlockedExchange(&g_busy, 0);
                return 0;
            }
            wchar_t full[MAX_PATH];
            GetFullPathNameW(src, MAX_PATH, full, NULL);
            if (!file_exists(full)) {
                MessageBoxW(hwnd, L"文件不存在", L"luac2c", MB_ICONWARNING);
                InterlockedExchange(&g_busy, 0);
                return 0;
            }
            struct job *j = (struct job *)calloc(1, sizeof *j);
            wcscpy(j->src, full);
            j->mode = SendMessageW(GetDlgItem(hwnd, IDC_RB_SEED), BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 :
                      (SendMessageW(GetDlgItem(hwnd, IDC_RB_STATIC), BM_GETCHECK, 0, 0) == BST_CHECKED ? 2 : 0);
            wchar_t sbuf[32];
            GetWindowTextW(GetDlgItem(hwnd, IDC_SEED), sbuf, 32);
            j->seed = wcstoul(sbuf, NULL, 0);
            j->nopool = SendMessageW(GetDlgItem(hwnd, IDC_NOPOOL), BM_GETCHECK, 0, 0) == BST_CHECKED;
            j->annot  = SendMessageW(GetDlgItem(hwnd, IDC_ANNOTATE), BM_GETCHECK, 0, 0) == BST_CHECKED;
            j->full = (id == IDC_RUN);
            SYSTEMTIME st;
            GetLocalTime(&st);
            log_append(L"\r\n──── ");
            wchar_t ts[64];
            _snwprintf(ts, 64, L"%04u-%02u-%02u %02u:%02u:%02u  %ls\r\n",
                       st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, full);
            ts[63] = 0;
            log_append(ts);
            set_ui_busy(hwnd, TRUE);
            CloseHandle(CreateThread(NULL, 0, worker, j, 0, NULL));
            return 0;
        }
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ------------------------------------------------------------------ main */
int WINAPI WinMain(HINSTANCE hi, HINSTANCE hp, LPSTR cl, int show) {
    (void)hp; (void)cl;
    g_hInst = hi;
    InitializeCriticalSection(&g_cs);
    SetProcessDPIAware();

    GetModuleFileNameW(NULL, g_root, MAX_PATH);
    wchar_t *slash = wcsrchr(g_root, L'\\');
    if (slash) *slash = 0;
    joinpath(g_ini, MAX_PATH, g_root, L"luac2c_gui.ini");
    find_tools();

    g_font = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                         OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                         DEFAULT_PITCH, L"Microsoft YaHei UI");
    g_mono = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                         OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                         FIXED_PITCH | FF_MODERN, L"Consolas");

    WNDCLASSW wc;
    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = hi;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"luac2c_gui";
    RegisterClassW(&wc);

    HWND hwnd = CreateWindowExW(WS_EX_ACCEPTFILES, wc.lpszClassName,
        L"luac2c 客户端 — Lua 5.5 字节码 → Lua C API",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 876, 700, NULL, NULL, hi, NULL);
    g_hwnd = hwnd;
    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);

    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    DeleteCriticalSection(&g_cs);
    return (int)m.wParam;
}
