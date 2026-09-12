/*
** luac2c - Translate Lua 5.5 bytecode (.luac) to C source using the
**          Lua C API.  Reads a compiled Lua chunk, parses the prototype
**          tree, and emits a self-contained C file that, when compiled
**          and linked against liblua, reproduces the behaviour of the
**          original chunk.
**
** Usage:  luac2c input.luac -o output.c
**
** Known limitations:
**   - Only handles official bytecode format (LUAC_FORMAT = 0) of Lua 5.5.
**   - Debug information is discarded: error messages produced by the Lua
**     runtime carry no "file:line:" prefix and no local-variable names,
**     because the generated functions are C functions with no line info.
**   - Compile-time metamethod binding (MMBIN/MMBINI/MMBINK) is a no-op;
**     the preceding arithmetic / bitwise C API call already routes
**     through lua_arith, so metamethods still fire.
**   - Coroutines are not supported: the generated chunk cannot yield out
**     of a C function, so coroutine.wrap/resume across a translated
**     function will fail.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>

typedef uint32_t Instruction;
typedef uint8_t  lu_byte;

/* -------------------------------------------------------------------------
** OpMode + OpCode (from lopcodes.h of Lua 5.5)
** ------------------------------------------------------------------------- */
enum OpMode { iABC, ivABC, iABx, iAsBx, iAx, isJ };

typedef enum {
    OP_MOVE, OP_LOADI, OP_LOADF, OP_LOADK, OP_LOADKX,
    OP_LOADFALSE, OP_LFALSESKIP, OP_LOADTRUE, OP_LOADNIL,
    OP_GETUPVAL, OP_SETUPVAL,
    OP_GETTABUP, OP_GETTABLE, OP_GETI, OP_GETFIELD,
    OP_SETTABUP, OP_SETTABLE, OP_SETI, OP_SETFIELD,
    OP_NEWTABLE, OP_SELF,
    OP_ADDI, OP_ADDK, OP_SUBK, OP_MULK, OP_MODK, OP_POWK, OP_DIVK, OP_IDIVK,
    OP_BANDK, OP_BORK, OP_BXORK, OP_SHLI, OP_SHRI,
    OP_ADD, OP_SUB, OP_MUL, OP_MOD, OP_POW, OP_DIV, OP_IDIV,
    OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR,
    OP_MMBIN, OP_MMBINI, OP_MMBINK,
    OP_UNM, OP_BNOT, OP_NOT, OP_LEN, OP_CONCAT,
    OP_CLOSE, OP_TBC, OP_JMP,
    OP_EQ, OP_LT, OP_LE, OP_EQK, OP_EQI, OP_LTI, OP_LEI, OP_GTI, OP_GEI,
    OP_TEST, OP_TESTSET,
    OP_CALL, OP_TAILCALL, OP_RETURN, OP_RETURN0, OP_RETURN1,
    OP_FORLOOP, OP_FORPREP, OP_TFORPREP, OP_TFORCALL, OP_TFORLOOP,
    OP_SETLIST, OP_CLOSURE, OP_VARARG, OP_GETVARG, OP_ERRNNIL,
    OP_VARARGPREP, OP_EXTRAARG
} OpCode;

#define NUM_OPCODES ((int)OP_EXTRAARG + 1)

/* Instruction field positions and sizes */
#define SIZE_OP 7
#define POS_OP  0
#define POS_A   (POS_OP + SIZE_OP)
#define SIZE_A  8
#define POS_k   (POS_A + SIZE_A)
#define POS_B   (POS_k + 1)
#define SIZE_B  8
#define POS_C   (POS_B + SIZE_B)
#define SIZE_C  8
/* The ivABC variant overlaps iABC's B/C fields.  From the LSB the layout
** is  Op(7) | A(8) | k(1) | vB(6) | vC(10), so vB begins one bit above k.
** Reading it from POS_k picks up the k bit as vB's bit 0, which shifts
** every value left by one and doubles it. */
#define POS_vB  (POS_k + 1)
#define SIZE_vB 6
#define POS_vC  (POS_vB + SIZE_vB)
#define SIZE_vC 10
#define POS_Bx  POS_k
#define SIZE_Bx (SIZE_C + SIZE_B + 1)
#define POS_Ax  POS_A
#define SIZE_Ax (SIZE_Bx + SIZE_A)
#define POS_sJ  POS_A
#define SIZE_sJ (SIZE_Bx + SIZE_A)
#define MAXARG_Bx  ((1 << SIZE_Bx) - 1)
#define MAXARG_C   ((1 << SIZE_C) - 1)
#define MAXARG_sJ  ((1 << SIZE_sJ) - 1)
/* Signed arguments use excess-K: the offset is half of the *maximum value*
** of the field, i.e. ((1<<size) - 1) >> 1 -- not (1<<size) >> 1. */
#define OFFSET_sBx (MAXARG_Bx >> 1)
#define OFFSET_sC  (MAXARG_C  >> 1)
#define OFFSET_sJ  (MAXARG_sJ >> 1)
#define MAXARG_A   ((1 << SIZE_A) - 1)

/* opmode byte from lopcodes.c: bits 0..2 mode, bit 3 A, bit 4 T, bit 5 IT,
** bit 6 OT, bit 7 MM. */
static lu_byte OPCODES_MODE[NUM_OPCODES];
static int opmodes_loaded = 0;

static const char *const OP_NAMES[NUM_OPCODES] = {
    "MOVE","LOADI","LOADF","LOADK","LOADKX","LOADFALSE","LFALSESKIP",
    "LOADTRUE","LOADNIL","GETUPVAL","SETUPVAL","GETTABUP","GETTABLE",
    "GETI","GETFIELD","SETTABUP","SETTABLE","SETI","SETFIELD",
    "NEWTABLE","SELF","ADDI","ADDK","SUBK","MULK","MODK","POWK",
    "DIVK","IDIVK","BANDK","BORK","BXORK","SHLI","SHRI","ADD","SUB",
    "MUL","MOD","POW","DIV","IDIV","BAND","BOR","BXOR","SHL","SHR",
    "MMBIN","MMBINI","MMBINK","UNM","BNOT","NOT","LEN","CONCAT",
    "CLOSE","TBC","JMP","EQ","LT","LE","EQK","EQI","LTI","LEI",
    "GTI","GEI","TEST","TESTSET","CALL","TAILCALL","RETURN",
    "RETURN0","RETURN1","FORLOOP","FORPREP","TFORPREP","TFORCALL",
    "TFORLOOP","SETLIST","CLOSURE","VARARG","GETVARG","ERRNNIL",
    "VARARGPREP","EXTRAARG"
};

/* -------------------------------------------------------------------------
** Fatal diagnostics
**
** Anything the translator cannot reproduce faithfully must abort the
** translation with a clear message.  Emitting a comment and carrying on
** would quietly produce a C file that compiles and then misbehaves, which
** is the worst possible failure mode for a translator.
** ------------------------------------------------------------------------- */
static void fatal(const char *fmt, ...) {
    va_list ap;
    fputs("luac2c: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

/* -------------------------------------------------------------------------
** Instruction decode helpers
** ------------------------------------------------------------------------- */
static inline int getop(Instruction i)   { return (int)((i >> POS_OP) & 0x7F); }
static inline int getA(Instruction i)    { return (int)((i >> POS_A)  & 0xFF); }
static inline int getB(Instruction i)    { return (int)((i >> POS_B)  & 0xFF); }
static inline int getC(Instruction i)    { return (int)((i >> POS_C)  & 0xFF); }
static inline int getk(Instruction i)    { return (int)((i >> POS_k)  & 0x1); }
static inline int getvB(Instruction i)   { return (int)((i >> POS_vB) & 0x3F); }
static inline int getvC(Instruction i)   { return (int)((i >> POS_vC) & 0x3FF); }
static inline int getBx(Instruction i)   { return (int)((i >> POS_Bx) & MAXARG_Bx); }
static inline int getsBx(Instruction i)  { return getBx(i) - OFFSET_sBx; }
static inline int getAx(Instruction i)   { return (int)((i >> POS_Ax) & ((1 << SIZE_Ax) - 1)); }
static inline int getsJ(Instruction i)   { return ((int)((i >> POS_sJ) & ((1 << SIZE_sJ) - 1))) - OFFSET_sJ; }

/* -------------------------------------------------------------------------
** Bytecode stream
** ------------------------------------------------------------------------- */
typedef struct {
    FILE  *fp;
    int    err;
    char   errmsg[512];
    size_t off;      /* absolute offset in the dump, for loadAlign */
    char **strs;     /* saved strings, 1-based index idx == strs[idx-1] */
    int    nstr;
    int    strcap;
} Reader;

static void r_error(Reader *R, const char *fmt, ...) {
    if (R->err) return;
    R->err = 1;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(R->errmsg, sizeof(R->errmsg), fmt, ap);
    va_end(ap);
}

static int r_read1(Reader *R) {
    int c = fgetc(R->fp);
    if (c == EOF) { r_error(R, "unexpected end of file"); return 0; }
    R->off++;
    return c & 0xFF;
}

/* Lua 5.5 stores varints MSB-first: x = (x << 7) | (b & 0x7f), continuing
** while the high bit is set. */
static long long r_readvarint(Reader *R) {
    unsigned long long x = 0;
    int b, n = 0;
    do {
        b = r_read1(R);
        if (R->err) return 0;
        if (++n > 10) { r_error(R, "varint too long"); return 0; }
        x = (x << 7) | (unsigned long long)(b & 0x7F);
    } while (b & 0x80);
    return (long long)x;
}

static int r_readsize(Reader *R) { return (int)r_readvarint(R); }

/* zigzag-encoded integer (matches Lua's loadInteger) */
static long long r_readinteger(Reader *R) {
    unsigned long long cx = (unsigned long long)r_readvarint(R);
    if (R->err) return 0;
    if (cx & 1) return (long long)(~(cx >> 1));
    else        return (long long)(cx >> 1);
}

static double r_readnumber(Reader *R) {
    double d;
    if (fread(&d, sizeof(d), 1, R->fp) != 1) {
        r_error(R, "unexpected end of file reading number");
        return 0;
    }
    R->off += sizeof(d);
    return d;
}

static void r_checkliteral(Reader *R, const char *s) {
    while (*s) {
        int c = r_read1(R);
        if ((char)c != *s) { r_error(R, "bad literal"); return; }
        s++;
    }
}

static void r_readraw(Reader *R, void *buf, size_t n) {
    if (n == 0) return;
    if (fread(buf, 1, n, R->fp) != n) {
        r_error(R, "unexpected end of file");
        return;
    }
    R->off += n;
}

static void r_skip(Reader *R, size_t n) {
    if (n == 0) return;
    if (fseek(R->fp, (long)n, SEEK_CUR) != 0) {
        r_error(R, "fseek: %s", strerror(errno));
        return;
    }
    R->off += n;
}

/* Mirror of loadAlign: skip padding so R->off is a multiple of 'align'. */
static void r_align(Reader *R, size_t align) {
    size_t padding = align - (R->off % align);
    if (padding < align) r_skip(R, padding);
}

/* -------------------------------------------------------------------------
** Prototype structure (forward decls)
** ------------------------------------------------------------------------- */
typedef enum {
    KNIL    = 0x00,
    KFALSE  = 0x01,
    KTRUE   = 0x11,
    KINT    = 0x03,
    KFLT    = 0x13,
    KSHRSTR = 0x04,
    KLNGSTR = 0x14
} ConstTag;

typedef struct {
    int   tag;
    long long  i;
    double  n;
    char  *s;     /* owned */
} Constant;

typedef struct {
    int instack;
    int idx;
    int kind;
} UpvalDesc;

struct Proto;
typedef struct Proto Proto;

struct Proto {
    char  *source;
    int    linedefined;
    int    lastlinedefined;
    int    numparams;
    int    flag;
    int    maxstack;

    Instruction *code;
    int ncode;

    Constant *k;
    int sizek;

    UpvalDesc *upvalues;
    int nupvalues;

    /* Set by compute_captures():
    **   upbox[i]  - upvalue i is a shared cell (1-element table) rather than a
    **               plain value.  Only _ENV of the main chunk is a plain value;
    **               every upvalue we build ourselves is a cell, because a C
    **               closure cannot alias a stack slot.
    **   capreg[r] - register r is captured by some nested closure and may
    **               therefore need its cell resynchronised when written. */
    int *upbox;
    int *capreg;
    int  ncap;
    int *kmap;      /* K index -> constant-pool index */

    struct Proto **p;
    int sizep;
};

static Proto *proto_new(void) {
    Proto *p = (Proto*)calloc(1, sizeof(Proto));
    return p;
}

static void proto_free(Proto *p) {
    if (!p) return;
    free(p->source);
    free(p->code);
    for (int i = 0; i < p->sizek; i++) free(p->k[i].s);
    free(p->k);
    free(p->upvalues);
    free(p->upbox);
    free(p->capreg);
    free(p->kmap);
    for (int i = 0; i < p->sizep; i++) proto_free(p->p[i]);
    free(p->p);
    free(p);
}

static char *r_dup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = (char*)malloc(n);
    memcpy(r, s, n);
    return r;
}

static void r_savestring(Reader *R, const char *s) {
    if (R->nstr == R->strcap) {
        int cap = R->strcap ? R->strcap * 2 : 32;
        R->strs = (char**)realloc(R->strs, (size_t)cap * sizeof(char*));
        if (!R->strs) { fprintf(stderr, "oom\n"); exit(1); }
        R->strcap = cap;
    }
    R->strs[R->nstr++] = r_dup(s);
}

/* Returns a freshly allocated copy the caller owns, or NULL for a NULL string.
** size==0 means "reuse the saved string at the following index" (index 0 ==
** NULL); size>=1 is a new string of size-1 bytes, which gets saved. */
static char *r_readstring(Reader *R) {
    int sz = r_readsize(R);
    if (R->err) return NULL;
    if (sz == 0) {
        long long idx = r_readvarint(R);
        if (R->err) return NULL;
        if (idx == 0) return NULL;
        if (idx < 1 || idx > R->nstr) {
            r_error(R, "invalid string index %lld (have %d)", idx, R->nstr);
            return NULL;
        }
        return r_dup(R->strs[idx - 1]);
    }
    sz -= 1;
    char *buf = (char*)malloc((size_t)sz + 1);
    /* the dump includes the trailing '\0', so read sz+1 bytes */
    r_readraw(R, buf, (size_t)sz + 1);
    if (R->err) { free(buf); return NULL; }
    buf[sz] = 0;
    r_savestring(R, buf);
    return buf;
}

static void loadConstants(Reader *R, Proto *f) {
    int n = (int)r_readvarint(R);
    if (R->err) return;
    f->k = (Constant*)calloc((size_t)n, sizeof(Constant));
    f->sizek = n;
    for (int i = 0; i < n; i++) {
        Constant *c = &f->k[i];
        c->tag = r_read1(R);
        switch (c->tag) {
            case KNIL:    break;
            case KFALSE:  break;
            case KTRUE:   break;
            case KINT:    c->i = r_readinteger(R); break;
            case KFLT:    c->n = r_readnumber(R); break;
            case KSHRSTR:
            case KLNGSTR: c->s = r_readstring(R); break;
            default:
                r_error(R, "unknown constant tag 0x%02x", c->tag);
                return;
        }
    }
}

static void loadUpvalues(Reader *R, Proto *f) {
    int n = (int)r_readvarint(R);
    if (R->err) return;
    f->upvalues = (UpvalDesc*)calloc((size_t)n, sizeof(UpvalDesc));
    f->nupvalues = n;
    for (int i = 0; i < n; i++) {
        f->upvalues[i].instack = r_read1(R);
        f->upvalues[i].idx     = r_read1(R);
        f->upvalues[i].kind    = r_read1(R);
    }
}

static void loadFunction(Reader *R, Proto *f);

static void loadProtos(Reader *R, Proto *f) {
    int n = (int)r_readvarint(R);
    if (R->err) return;
    f->p = (Proto**)calloc((size_t)n, sizeof(Proto*));
    f->sizep = n;
    for (int i = 0; i < n; i++) {
        f->p[i] = proto_new();
        loadFunction(R, f->p[i]);
        if (R->err) return;
    }
}

static void loadDebug(Reader *R, Proto *f) {
    int n = (int)r_readvarint(R);                 /* lineinfo: n signed bytes */
    if (R->err) return;
    r_skip(R, (size_t)n);
    n = (int)r_readvarint(R);                     /* abslineinfo */
    if (R->err) return;
    if (n > 0) {
        r_align(R, sizeof(int));
        r_skip(R, (size_t)n * 2 * sizeof(int));   /* AbsLineInfo { int pc, line } */
    }
    n = (int)r_readvarint(R);                     /* locvars */
    if (R->err) return;
    for (int i = 0; i < n; i++) {
        char *s = r_readstring(R); free(s);
        r_readvarint(R); r_readvarint(R);
        if (R->err) return;
    }
    n = (int)r_readvarint(R);                     /* upvalue names */
    if (R->err) return;
    if (n != 0) n = f->nupvalues;
    for (int i = 0; i < n; i++) {
        char *s = r_readstring(R); free(s);
        if (R->err) return;
    }
}

static void loadCode(Reader *R, Proto *f) {
    int n = (int)r_readvarint(R);
    if (R->err) return;
    if (n < 0) { r_error(R, "bad code size %d", n); return; }
    r_align(R, sizeof(Instruction));
    f->code = (Instruction*)calloc((size_t)n + 1, sizeof(Instruction));
    f->ncode = n;
    r_readraw(R, f->code, (size_t)n * sizeof(Instruction));
}

static void loadFunction(Reader *R, Proto *f) {
    f->linedefined     = (int)r_readvarint(R);
    f->lastlinedefined = (int)r_readvarint(R);
    f->numparams       = r_read1(R);
    f->flag            = r_read1(R);
    f->maxstack        = r_read1(R);
    if (R->err) return;
    loadCode(R, f);
    if (R->err) return;
    loadConstants(R, f);
    if (R->err) return;
    loadUpvalues(R, f);
    if (R->err) return;
    loadProtos(R, f);
    if (R->err) return;
    f->source = r_readstring(R);
    if (R->err) return;
    loadDebug(R, f);
}

static void loadHeader(Reader *R) {
    int c = r_read1(R);
    if (c != 0x1B) { r_error(R, "not a binary Lua chunk (first byte 0x%02x)", c); return; }
    r_checkliteral(R, "Lua");
    int ver = r_read1(R);
    int fmt = r_read1(R);
    if (ver != 0x55) r_error(R, "unsupported Lua version byte 0x%02x (only 0x55 / 5.5 supported)", ver);
    if (fmt != 0)    r_error(R, "unsupported format %d", fmt);
    r_checkliteral(R, "\x19\x93\r\n\x1a\n");
    /* checknum: 4 blocks of (size_byte, then size raw bytes).
     * Use static buffers to make the call syntactically valid. */
    int isz = r_read1(R); { char buf[8] = {0}; r_readraw(R, buf, (size_t)isz); }
    int instsz = r_read1(R); { char buf[8] = {0}; r_readraw(R, buf, (size_t)instsz); }
    int intsz = r_read1(R); { char buf[8] = {0}; r_readraw(R, buf, (size_t)intsz); }
    int numsz = r_read1(R); { char buf[8] = {0}; r_readraw(R, buf, (size_t)numsz); }
    (void)0;
}

/* -------------------------------------------------------------------------
** opmodes table
** ------------------------------------------------------------------------- */
static void load_opmodes(void) {
    if (opmodes_loaded) return;
    opmodes_loaded = 1;
    OPCODES_MODE[OP_MOVE]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_LOADI]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iAsBx;
    OPCODES_MODE[OP_LOADF]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iAsBx;
    OPCODES_MODE[OP_LOADK]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABx;
    OPCODES_MODE[OP_LOADKX]      = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABx;
    OPCODES_MODE[OP_LOADFALSE]   = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_LFALSESKIP]  = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_LOADTRUE]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_LOADNIL]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_GETUPVAL]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SETUPVAL]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_GETTABUP]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_GETTABLE]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_GETI]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_GETFIELD]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SETTABUP]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_SETTABLE]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_SETI]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_SETFIELD]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_NEWTABLE]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|ivABC;
    OPCODES_MODE[OP_SELF]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_ADDI]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_ADDK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SUBK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_MULK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_MODK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_POWK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_DIVK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_IDIVK]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BANDK]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BORK]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BXORK]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SHLI]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SHRI]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_ADD]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SUB]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_MUL]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_MOD]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_POW]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_DIV]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_IDIV]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BAND]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BOR]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BXOR]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SHL]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_SHR]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_MMBIN]       = (1<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_MMBINI]      = (1<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_MMBINK]      = (1<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_UNM]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_BNOT]        = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_NOT]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_LEN]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_CONCAT]      = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_CLOSE]       = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_TBC]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_JMP]         = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|isJ;
    OPCODES_MODE[OP_EQ]          = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_LT]          = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_LE]          = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_EQK]         = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_EQI]         = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_LTI]         = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_LEI]         = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_GTI]         = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_GEI]         = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_TEST]        = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_TESTSET]     = (0<<7)|(0<<6)|(0<<5)|(1<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_CALL]        = (0<<7)|(1<<6)|(1<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_TAILCALL]    = (0<<7)|(1<<6)|(1<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_RETURN]      = (0<<7)|(0<<6)|(1<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_RETURN0]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_RETURN1]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_FORLOOP]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABx;
    OPCODES_MODE[OP_FORPREP]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABx;
    OPCODES_MODE[OP_TFORPREP]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABx;
    OPCODES_MODE[OP_TFORCALL]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_TFORLOOP]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABx;
    OPCODES_MODE[OP_SETLIST]     = (0<<7)|(0<<6)|(1<<5)|(0<<4)|(0<<3)|ivABC;
    OPCODES_MODE[OP_CLOSURE]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABx;
    OPCODES_MODE[OP_VARARG]      = (0<<7)|(1<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_GETVARG]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(1<<3)|iABC;
    OPCODES_MODE[OP_ERRNNIL]     = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABx;
    OPCODES_MODE[OP_VARARGPREP]  = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iABC;
    OPCODES_MODE[OP_EXTRAARG]    = (0<<7)|(0<<6)|(0<<5)|(0<<4)|(0<<3)|iAx;
}

/* -------------------------------------------------------------------------
** Emitter
**
** Register model
** --------------
** Registers are materialised as *real* Lua stack slots of the generated C
** closure.  Register r lives at absolute stack index  R(r) == b + r + 1,
** where 'b' is a runtime base offset (normally 0; non-zero only for
** functions with hidden varargs, which need the extra arguments shuffled
** out of the way of the register frame).
**
** A second variable 'top' mirrors the VM's L->top: it is the number of
** live stack values plus one, expressed in the same (shifted) index space.
** It is only consulted by the "open" instructions (CALL/RETURN/TAILCALL
** with B==0 and SETLIST with vB==0), and it is updated after every
** multiple-result operation.
** ------------------------------------------------------------------------- */

/* Proto flags, from lobject.h */
#define PF_VAHID  1   /* function has hidden vararg arguments */
#define PF_VATAB  2   /* function has a vararg table         */

#define MAXARG_vC  ((1 << SIZE_vC) - 1)

static int is_kstr(int tag);   /* forward decl, defined below */

typedef struct {
    FILE *out;
    int   next_label;
    int   nlabels;
    int  *labels;          /* labels[pc] = id or 0 */
} Emitter;

static void E_reset(Emitter *E) {
    free(E->labels);
    E->labels = NULL;
    E->nlabels = 0;
    E->next_label = 0;
}

static int E_LABEL(Emitter *E, int pc) {
    if (pc < 0) return 0;
    if (pc >= E->nlabels) {
        int nnew = pc + 16;
        int *nlabels = (int*)realloc(E->labels, (size_t)nnew * sizeof(int));
        if (!nlabels) { fprintf(stderr, "oom\n"); exit(1); }
        for (int i = E->nlabels; i < nnew; i++) nlabels[i] = 0;
        E->labels = nlabels;
        E->nlabels = nnew;
    }
    if (E->labels[pc] == 0) E->labels[pc] = ++E->next_label;
    return E->labels[pc];
}

static void emit(Emitter *E, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(E->out, fmt, ap);
    va_end(ap);
}

static void cemit_str(FILE *out, const char *s) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char*)s; *p; p++) {
        unsigned c = *p;
        switch (c) {
            case '\\': fputs("\\\\", out); break;
            case '"':  fputs("\\\"", out); break;
            case '\n': fputs("\\n", out);  break;
            case '\r': fputs("\\r", out);  break;
            case '\t': fputs("\\t", out);  break;
            default:
                if (c < 0x20 || c >= 0x7F) fprintf(out, "\\x%02x", c);
                else fputc(c, out);
        }
    }
    fputc('"', out);
}

/* Emit C source that pushes constant K[idx] on the Lua stack. */
static int  g_diversify = 1;   /* 0 = plain, fully predictable output */
static int  g_annotate  = 0;   /* keep per-instruction opcode annotations */
static int  g_pool      = 1;   /* build constants at run time            */
static unsigned long long g_rng  = 0x243F6A8885A308D3ULL;
static unsigned long long g_nctr = 0;

static void rng_seed(unsigned long long s) {
    g_rng = s ? s : 0x9E3779B97F4A7C15ULL;
}
static unsigned rng_u32(void) {
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17;
    return (unsigned)(g_rng >> 32);
}
static unsigned rng_below(unsigned n) {
    return n ? (unsigned)(((unsigned long long)rng_u32() * (unsigned long long)n) >> 32) : 0;
}
static char *g_kblob = NULL, *g_kbuild = NULL, *g_kxor = NULL;

/* Static-hardening switches.  Both default on in diversify mode and are
** forced off by --static, so the reproducible baseline stays readable. */
static int  g_flatten  = 1;    /* 1 = flatten every body into a state machine */
static int  g_split    = 1;    /* 1 = one pointer-reached function per block  */
static int  g_indirect = 1;    /* 1 = route Lua API calls through pointers   */
static unsigned g_st_a = 1u;   /* affine state encoding: st -> (id*a + b)    */
static unsigned g_st_b = 0u;
static unsigned g_pk1 = 0u, g_pk2 = 0u;   /* constant-pool key, two shares    */

/* ---------------------------------------------------------------------------
** Indirect Lua-API dispatch
**
** Every real function the generated code can reach is listed here, in a fixed
** order.  Names that lua.h/lauxlib.h/lualib.h define as *macros* (lua_call,
** lua_pop, lua_insert, lua_isnil, lua_tostring, luaL_addchar, luaL_openlibs,
** ...) are deliberately absent: their bodies already expand into calls on the
** real functions below, so redirecting those is enough to catch them too.
** ------------------------------------------------------------------------- */
static const char *const g_api_names[] = {
    "lua_arith",    "lua_callk",     "lua_close",        "lua_closeslot",
    "lua_compare",  "lua_concat",    "lua_copy",         "lua_createtable",
    "lua_geti",     "lua_gettable",  "lua_gettop",       "lua_isinteger",
    "lua_len",      "lua_pcallk",    "lua_pushboolean",  "lua_pushcclosure",
    "lua_pushinteger","lua_pushlstring","lua_pushnil",   "lua_pushnumber",
    "lua_pushvalue","lua_rawequal",  "lua_rawgeti",      "lua_rawseti",
    "lua_rotate",   "lua_setfield",  "lua_seti",         "lua_settable",
    "lua_settop",   "lua_toboolean", "lua_toclose",      "lua_tointegerx",
    "lua_tonumberx","lua_tolstring", "lua_type",
    "luaL_buffinit","luaL_checkstack","luaL_error",      "luaL_newstate",
    "luaL_openselectedlibs",         "luaL_prepbuffsize","luaL_pushresult"
};
#define L2C_NGAPI ((int)(sizeof g_api_names / sizeof g_api_names[0]))

static unsigned g_api_slot[L2C_NGAPI];   /* table index chosen for each name */
static unsigned long long g_api_k64[L2C_NGAPI];   /* per-entry xor mask      */
static int      g_api_ntab = 0;          /* total slots in the emitted table */
static char    *g_api_tag  = NULL;       /* random prefix for emitted names  */

/* Scatter the API entries over a table with a few unused holes, so neither the
** slot of a given call nor its neighbours say anything about which function it
** reaches.  Uses the same RNG as every other naming decision. */
static void plan_api_table(void) {
    int n = L2C_NGAPI;
    int size = n + 4 + (int)rng_below(12);
    unsigned tmp[L2C_NGAPI + 16];
    for (int i = 0; i < size; i++) tmp[i] = (unsigned)i;
    for (int i = size - 1; i > 0; i--) {
        int j = (int)rng_below((unsigned)(i + 1));
        unsigned t = tmp[i]; tmp[i] = tmp[j]; tmp[j] = t;
    }
    for (int i = 0; i < n; i++) {
        g_api_slot[i] = tmp[i];
        g_api_k64[i]  = ((unsigned long long)rng_u32() << 32) | rng_u32();
    }
    g_api_ntab = size;
}

/* Constant-pool keystream.  Positional only in shape; the value is a keyed
** mixer so the three constants that used to describe it no longer invert it
** on inspection.  The generated decoder emits exactly this expression. */
static unsigned pool_xor(int i, int j) {
    unsigned x = (g_pk1 ^ g_pk2)
               ^ (unsigned)i * 0x9E3779B9u
               ^ (unsigned)j * 0x85EBCA6Bu;
    x ^= x >> 15; x *= 0x2545F491u; x ^= x >> 13;
    return x & 0xffu;
}

/* Affine encoding of a label id into the state-machine state space.  'a' is
** odd, so the map is a bijection modulo 2^32 and distinct ids stay distinct. */
static unsigned st_enc(int id) {
    return (unsigned)(((unsigned long long)(unsigned)id * g_st_a + g_st_b) & 0xFFFFFFFFULL);
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *q = (char*)malloc(n);
    if (!q) { fprintf(stderr, "out of memory\n"); exit(1); }
    memcpy(q, s, n);
    return q;
}
static char *mkname(const char *pfx) {
    char tmp[64];
    snprintf(tmp, sizeof tmp, "%s%02x%llx", pfx,
             (unsigned)(rng_u32() & 0xffu), g_nctr++ & 0xfffffULL);
    return xstrdup(tmp);
}

/* (defined further down, next to the rest of the pool machinery) */
static int pool_intern(Proto *p, int idx);

/* Emit C source that pushes constant K[idx].  Strings (and, with
** --pool-all, numbers) are fetched from the run-time constant pool so that
** they never appear as literals in the object file. */
static void emit_pushk(Emitter *E, Proto *p, int idx) {
    if (idx < 0 || idx >= p->sizek)
        fatal("%s: constant %d is out of range (%d constants)",
              p->source ? p->source : "?", idx, p->sizek);
    Constant *c = &p->k[idx];
    switch (c->tag) {
        case KNIL:   emit(E, "lua_pushnil(L)"); break;
        case KFALSE: emit(E, "lua_pushboolean(L, 0)"); break;
        case KTRUE:  emit(E, "lua_pushboolean(L, 1)"); break;
        case KINT:
            if (g_pool >= 2) emit(E, "lua_rawgeti(L, KP, %d)", pool_intern(p, idx) + 1);
            else             emit(E, "lua_pushinteger(L, %lldLL)", (long long)c->i);
            break;
        case KFLT:
            if (g_pool >= 2) emit(E, "lua_rawgeti(L, KP, %d)", pool_intern(p, idx) + 1);
            else             emit(E, "lua_pushnumber(L, (lua_Number)%.17g)", c->n);
            break;
        default:
            if (g_pool >= 1) emit(E, "lua_rawgeti(L, KP, %d)", pool_intern(p, idx) + 1);
            else {
                emit(E, "lua_pushlstring(L, ");
                cemit_str(E->out, c->s);
                fprintf(E->out, ", %d)", (int)strlen(c->s));
            }
            break;
    }
}

/* Emit C source that pushes RK(c): K[c] when k is set, else R[c]. */
static void emit_pushrk(Emitter *E, Proto *p, int c, int k) {
    if (k) emit_pushk(E, p, c);
    else   emit(E, "lua_pushvalue(L, R(%d))", c);
}

/* Emit C source that pushes the *key* K[idx] (a string) on the stack, for
** use with lua_gettable / lua_settable.  Every caller stores through the key,
** so a non-string constant would silently drop the access -- abort instead. */
static int emit_kkey(Emitter *E, Proto *p, int idx) {
    if (idx < 0 || idx >= p->sizek || !is_kstr(p->k[idx].tag))
        fatal("%s: constant %d is not a string key",
              p->source ? p->source : "?", idx);
    if (g_pool >= 1) { emit(E, "lua_rawgeti(L, KP, %d)", pool_intern(p, idx) + 1); return 1; }
    emit(E, "lua_pushlstring(L, ");
    cemit_str(E->out, p->k[idx].s);
    fprintf(E->out, ", %d)", (int)strlen(p->k[idx].s));
    return 1;
}

static const char *arith_op_str(int op) {
    switch (op) {
        case OP_ADD:  return "LUA_OPADD";
        case OP_SUB:  return "LUA_OPSUB";
        case OP_MUL:  return "LUA_OPMUL";
        case OP_MOD:  return "LUA_OPMOD";
        case OP_POW:  return "LUA_OPPOW";
        case OP_DIV:  return "LUA_OPDIV";
        case OP_IDIV: return "LUA_OPIDIV";
        case OP_BAND: return "LUA_OPBAND";
        case OP_BOR:  return "LUA_OPBOR";
        case OP_BXOR: return "LUA_OPBXOR";
        case OP_SHL:  return "LUA_OPSHL";
        case OP_SHR:  return "LUA_OPSHR";
        case OP_ADDI: case OP_ADDK: return "LUA_OPADD";
        case OP_SUBK: return "LUA_OPSUB";
        case OP_MULK: return "LUA_OPMUL";
        case OP_MODK: return "LUA_OPMOD";
        case OP_POWK: return "LUA_OPPOW";
        case OP_DIVK: return "LUA_OPDIV";
        case OP_IDIVK:return "LUA_OPIDIV";
        case OP_BANDK:return "LUA_OPBAND";
        case OP_BORK: return "LUA_OPBOR";
        case OP_BXORK:return "LUA_OPBXOR";
        case OP_SHLI: return "LUA_OPSHL";
        case OP_SHRI: return "LUA_OPSHR";
        case OP_UNM:  return "LUA_OPUNM";
        case OP_BNOT: return "LUA_OPBNOT";
    }
    return "LUA_OPADD";
}

static int is_kstr(int tag) { return tag == KSHRSTR || tag == KLNGSTR; }

/* -------------------------------------------------------------------------
** Translation-time diversification
**
** A byte-for-byte predictable translation is trivial to fingerprint: every
** build emits the same helper names, the same R(r) = b+r+1 register layout,
** the same canned API sequence per opcode, the same string literals, and a
** per-instruction opcode comment in front of every instruction - which hands
** the reader the original bytecode layout for free.  The knobs below are drawn
** from a seed so that each build produces a differently shaped, but
** semantically identical, C file:
**
**   register layout   R(r) is a per-function permutation (table or xor),
**                     not the identity map, so stack slots cannot be read
**                     back as register numbers
**   constant pool     strings (and numbers) are built at run time from an
**                     encoded blob, so they never appear as literals
**   helper instances  every proto gets its own copy of the runtime helpers
**                     under its own name, so recognising one function does
**                     not recognise the whole file
**   identifiers       function / helper / local names are random
**   comments          the pc/opcode markers are dropped by default
**
** This is diversification, not obfuscation: no opaque predicates, no
** control-flow flattening, no dead code - the emitted control flow still
** mirrors the bytecode one-to-one and stays debuggable.
** ------------------------------------------------------------------------- */
/* Per-function translation choices. */
typedef struct {
    int   fsz;                  /* size of the materialised frame */
    int   mode;                 /* 0: permutation table, 1: xor permutation */
    int   xmask;
    int  *perm;
    char *fn;                   /* C name of this function */
    char *mapname;              /* name of the permutation table (mode 0) */
    char *vb, *vt, *vn;         /* names behind the b / top / ne macros */
    char *h_prep, *h_loop, *h_prep_lim; /* forprep / forloop / forlimit */
    char *h_bget, *h_bsync, *h_bpull, *h_ball;   /* box helpers */
    char *h_vidx;                                /* vararg-index key decoder */
    int   need_loop, need_box, need_varg;
} FnCtx;

/* -------------------------------------------------------------------------
** Constant pool
** ------------------------------------------------------------------------- */
typedef struct { int tag; long long i; double n; char *s; } PoolEnt;
static PoolEnt *g_pool_tab = NULL;
static int g_pool_n = 0, g_pool_cap = 0;

static int pool_intern(Proto *p, int idx);   /* index of K[idx] in the pool */

static char **g_fnames = NULL;   /* per-proto C function names */

/* Choose this proto's register layout and helper names. */
static void plan_function(FnCtx *C, Proto *p) {
    int maxstack = p->maxstack > 0 ? p->maxstack : 1;
    int nparams  = p->numparams;
    int isvatab  = (p->flag & PF_VATAB) != 0;
    /* Registers [0, fixed) keep their natural slot: they hold the incoming
    ** parameters (and, for VATAB protos, the vararg table), which the calling
    ** convention places at b+1... anyway.  Everything above can move. */
    int fixed = nparams + (isvatab ? 1 : 0);
    if (fixed > maxstack) fixed = maxstack;

    memset(C, 0, sizeof *C);
    C->fsz   = maxstack + (g_diversify ? (int)rng_below(9) : 0);
    C->perm  = (int*)malloc((size_t)maxstack * sizeof(int));
    for (int i = 0; i < maxstack; i++) C->perm[i] = i;

    /* Registers targeted by OP_TBC -- and the generic-for closing slot that
    ** OP_TFORPREP marks -- must keep their natural slot.  lua_toclose
    ** requires to-be-closed slots to be marked in strictly increasing stack
    ** order (luaF_newtbcupval asserts level > L->tbclist.p), and lua_closeslot
    ** / luaF_close then walk that chain by physical address.  A free
    ** permutation would move a later <close> below an earlier one and corrupt
    ** the chain, so those slots are pinned and only the rest is shuffled. */
    unsigned char *pinned = (unsigned char*)calloc((size_t)maxstack, 1);
    int npinned = 0;
    if (pinned) {
        for (int i = 0; i < p->ncode; i++) {
            int op = getop(p->code[i]);
            int a;
            if (op == OP_TBC) {
                a = getA(p->code[i]);
            } else if (op == OP_TFORPREP) {
                /* OP_TFORPREP swaps R[A+2] (control) with R[A+3] (closing) and
                ** then marks the closing value -- now back in R[A+2] -- as
                ** to-be-closed, so that is the slot that must stay put. */
                a = getA(p->code[i]) + 2;
            } else {
                continue;
            }
            if (a >= 0 && a < maxstack && !pinned[a]) { pinned[a] = 1; npinned++; }
        }
    }

    C->mode = 0;
    if (g_diversify && fixed == 0 && npinned == 0) {
        /* xor permutation needs a power-of-two frame; it leaves no table.
        ** It is not order preserving, so it is only safe with no TBC slot. */
        int f = 1;
        while (f < C->fsz) f <<= 1;
        if (f <= 256) {
            C->fsz = f;
            C->mode = 1;
            C->xmask = (int)rng_below((unsigned)f);
        }
    } else if (g_diversify) {
        /* Fisher-Yates over the movable slots in [fixed, maxstack), i.e. the
        ** locals and temporaries that are not pinned as to-be-closed. */
        int *mov = (int*)malloc((size_t)maxstack * sizeof(int));
        int nm = 0;
        if (mov) {
            for (int i = fixed; i < maxstack; i++)
                if (!pinned[i]) mov[nm++] = i;
            for (int i = nm - 1; i > 0; i--) {
                int j = (int)rng_below((unsigned)(i + 1));
                int a = mov[i], b = mov[j];
                int t = C->perm[a]; C->perm[a] = C->perm[b]; C->perm[b] = t;
            }
            free(mov);
        }
    }
    free(pinned);

    C->fn    = g_diversify ? mkname("lf") : NULL;
    C->vb    = mkname("v");
    C->vt    = mkname("v");
    C->vn    = mkname("v");

    for (int i = 0; i < p->ncode; i++) {
        int op = getop(p->code[i]);
        if (op == OP_FORPREP || op == OP_FORLOOP) C->need_loop = 1;
        if (op == OP_GETVARG) C->need_varg = 1;
    }
    C->need_box = (p->ncap > 0);
    if (C->need_loop) {
        C->h_prep     = mkname("hp");
        C->h_loop     = mkname("hl");
        C->h_prep_lim = mkname("hm");
    }
    if (C->need_box) {
        C->h_bget  = mkname("bg");
        C->h_bsync = mkname("bs");
        C->h_bpull = mkname("bp");
        C->h_ball  = mkname("ba");
    }
    if (C->need_varg) C->h_vidx = mkname("vi");
    /* mode 0 always needs a materialised permutation table; the name is
    ** randomised under --seed but must exist even in --static mode, since
    ** the emitter keys off mode alone. */
    if (C->mode == 0) C->mapname = mkname("rm");
    else              C->mapname = NULL;
}

/* Intern constant K[idx] of 'p' in the run-time pool; returns its index. */
static int pool_intern(Proto *p, int idx) {
    if (idx < 0 || idx >= p->sizek) return -1;
    if (!p->kmap) {
        int n = p->sizek > 0 ? p->sizek : 1;
        p->kmap = (int*)malloc((size_t)n * sizeof(int));
        if (!p->kmap) { fprintf(stderr, "out of memory\n"); exit(1); }
        for (int i = 0; i < n; i++) p->kmap[i] = -1;
    }
    if (p->kmap[idx] >= 0) return p->kmap[idx];
    if (g_pool_n >= g_pool_cap) {
        g_pool_cap = g_pool_cap ? g_pool_cap * 2 : 64;
        g_pool_tab = (PoolEnt*)realloc(g_pool_tab, (size_t)g_pool_cap * sizeof(PoolEnt));
        if (!g_pool_tab) { fprintf(stderr, "out of memory\n"); exit(1); }
    }
    Constant *c = &p->k[idx];
    PoolEnt *e = &g_pool_tab[g_pool_n];
    e->tag = c->tag; e->i = 0; e->n = 0.0; e->s = NULL;
    if (c->tag == KINT)      e->i = (long long)c->i;
    else if (c->tag == KFLT) e->n = c->n;
    else                     e->s = xstrdup(c->s);
    p->kmap[idx] = g_pool_n;
    return g_pool_n++;
}

/* Emit a C string literal for K[idx]; returns 0 when it is not a string.
** Only used where a genuine C literal is required (error messages). */
static int emit_kstr(Emitter *E, Proto *p, int idx) {
    if (idx < 0 || idx >= p->sizek || !is_kstr(p->k[idx].tag)) return 0;
    cemit_str(E->out, p->k[idx].s);
    return 1;
}

static int proto_id(Proto *root, Proto *target) {
    if (target == root) return 0;
    Proto *stack[2048]; int idx[2048]; int top = 0;
    stack[top] = root; idx[top] = 0; top++;
    int id = 0;
    while (top > 0) {
        Proto *q = stack[top-1]; int i = idx[top-1];
        if (i >= q->sizep) { top--; continue; }
        idx[top-1] = i+1;
        id++;
        if (q->p[i] == target) return id;
        if (top < 2040) { stack[top] = q->p[i]; idx[top] = 0; top++; }
    }
    return -1;
}

static int count_nested(Proto *root) {
    int n = 0;
    Proto *stack[2048]; int idx[2048]; int top = 0;
    stack[top] = root; idx[top] = 0; top++;
    while (top > 0) {
        Proto *q = stack[top-1]; int i = idx[top-1];
        if (i >= q->sizep) { top--; continue; }
        idx[top-1] = i+1;
        n++;
        if (top < 2040) { stack[top] = q->p[i]; idx[top] = 0; top++; }
    }
    return n;
}

static void flatten_protos(Proto *root, Proto **out, int *count) {
    out[0] = root;
    *count = 1;
    Proto *stack[2048]; int idx[2048]; int top = 0;
    stack[top] = root; idx[top] = 0; top++;
    while (top > 0) {
        Proto *q = stack[top-1]; int i = idx[top-1];
        if (i >= q->sizep) { top--; continue; }
        idx[top-1] = i+1;
        if (*count < 4096) out[(*count)++] = q->p[i];
        if (top < 2040) { stack[top] = q->p[i]; idx[top] = 0; top++; }
    }
}

/* Decide, for every upvalue of every proto, whether it is a plain value or a
** shared cell, and record which registers of each proto get captured.
**
** A C closure's upvalues are copies of stack values -- there is no C API to
** make one alias a live stack slot -- so any upvalue that must behave like a
** Lua upvalue (shared, writable) is represented as a one-element table.
** _ENV of the main chunk is handed over by main() as a plain value. */
static void compute_captures (Proto *p) {
    int mstack = p->maxstack > 0 ? p->maxstack : 1;
    if (p->upbox == NULL)   /* may already be set by the parent */
        p->upbox = (int*)calloc((size_t)(p->nupvalues > 0 ? p->nupvalues : 1), sizeof(int));
    p->capreg = (int*)calloc((size_t)mstack, sizeof(int));
    p->ncap = 0;
    for (int i = 0; i < p->sizep; i++) {
        Proto *c = p->p[i];
        /* Fill in the child's upvalue kinds *before* recursing: its own
        ** children inherit them for the upvalues it forwards. */
        c->upbox = (int*)calloc((size_t)(c->nupvalues > 0 ? c->nupvalues : 1), sizeof(int));
        for (int u = 0; u < c->nupvalues; u++) {
            if (c->upvalues[u].instack) {
                int r = c->upvalues[u].idx;
                c->upbox[u] = 1;                       /* a cell we create */
                if (r >= 0 && r < mstack && !p->capreg[r]) {
                    p->capreg[r] = 1;
                    p->ncap++;
                }
            } else {
                int pi = c->upvalues[u].idx;
                c->upbox[u] = (pi >= 0 && pi < p->nupvalues) ? p->upbox[pi] : 0;
            }
        }
        compute_captures(c);
    }
}

/* -------------------------------------------------------------------------
** Input validation
**
** Everything the emitter indexes by hand -- constants, nested prototypes,
** upvalues, register numbers, jump targets -- is checked up front.  A
** malformed chunk then aborts the translation with a precise message instead
** of reading out of bounds here or emitting C that overruns the register
** frame at run time.
** ------------------------------------------------------------------------- */
static void validate_req(int ok, const char *what, int pc, Proto *p, int val) {
    if (!ok)
        fatal("%s: instruction %d (%s): %s is %d, out of range",
              p->source ? p->source : "?", pc,
              OP_NAMES[getop(p->code[pc])], what, val);
}

static void validate_proto(Proto *p) {
    const char *src = p->source ? p->source : "?";
    if (p->ncode < 0 || p->sizek < 0 || p->sizep < 0 ||
        p->nupvalues < 0 || p->maxstack < 0 || p->maxstack > 255)
        fatal("%s: implausible prototype header (ncode=%d sizek=%d sizep=%d "
              "nupvalues=%d maxstack=%d)", src,
              p->ncode, p->sizek, p->sizep, p->nupvalues, p->maxstack);

    for (int pc = 0; pc < p->ncode; pc++) {
        Instruction ins = p->code[pc];
        int op = getop(ins);
        int A = getA(ins), B = getB(ins), C = getC(ins), k = getk(ins);
        int Bx = getBx(ins);

        if (op < 0 || op >= NUM_OPCODES)
            fatal("%s: instruction %d has unknown opcode %d", src, pc, op);

        /* A holds a register for every opcode except the two that pack a wide
        ** immediate into the A bits (sJ / Ax). */
        if (op != OP_JMP && op != OP_EXTRAARG && p->maxstack > 0)
            validate_req(A < p->maxstack, "register A", pc, p, A);

        switch (op) {
            case OP_LOADK:
                validate_req(Bx < p->sizek, "constant Bx", pc, p, Bx);
                break;
            case OP_LOADKX: {
                if (pc + 1 >= p->ncode || getop(p->code[pc + 1]) != OP_EXTRAARG)
                    fatal("%s: instruction %d: OP_LOADKX is not followed by "
                          "OP_EXTRAARG", src, pc);
                int kidx = getAx(p->code[pc + 1]);
                validate_req(kidx < p->sizek, "constant Ax", pc, p, kidx);
                break;
            }
            case OP_EQK:
                validate_req(B < p->sizek, "constant B", pc, p, B);
                break;
            /* String-key operands: the emitter needs K[idx] to be a string,
            ** otherwise it would have to drop the access entirely. */
            case OP_GETTABUP: case OP_GETFIELD: case OP_SELF:
                validate_req(C < p->sizek, "constant C", pc, p, C);
                if (C < p->sizek && !is_kstr(p->k[C].tag))
                    fatal("%s: instruction %d (%s): K[%d] is not a string key",
                          src, pc, OP_NAMES[op], C);
                if (op == OP_SELF)   /* also writes R[A+1] */
                    validate_req(A + 1 < p->maxstack, "register A+1", pc, p, A + 1);
                break;
            case OP_SETTABUP: case OP_SETFIELD:
                validate_req(B < p->sizek, "constant B", pc, p, B);
                if (B < p->sizek && !is_kstr(p->k[B].tag))
                    fatal("%s: instruction %d (%s): K[%d] is not a string key",
                          src, pc, OP_NAMES[op], B);
                validate_req(!k || C < p->sizek, "constant C", pc, p, C);
                break;
            /* RK(C): with k set, C names a constant instead of a register. */
            case OP_SETTABLE: case OP_SETI:
                validate_req(!k || C < p->sizek, "constant C", pc, p, C);
                break;
            /* These always take a constant in C (no k flag). */
            case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_MODK:
            case OP_POWK: case OP_DIVK: case OP_IDIVK:
            case OP_BANDK: case OP_BORK: case OP_BXORK:
                validate_req(C < p->sizek, "constant C", pc, p, C);
                break;
            case OP_ERRNNIL:
                /* Bx == 0 means "name unavailable"; otherwise it names K[Bx-1] */
                validate_req(Bx == 0 || Bx <= p->sizek, "constant Bx", pc, p, Bx);
                break;
            case OP_CLOSURE:
                validate_req(Bx < p->sizep, "prototype Bx", pc, p, Bx);
                break;
            case OP_GETUPVAL: case OP_SETUPVAL:
                validate_req(B < p->nupvalues, "upvalue B", pc, p, B);
                break;
            case OP_TBC:
                validate_req(A < p->maxstack, "to-be-closed slot A", pc, p, A);
                break;
            case OP_TFORPREP:
                /* the control block is R[A]..R[A+3] (iterator/state/control/closing) */
                validate_req(A + 3 < p->maxstack, "generic-for frame A+3", pc, p, A + 3);
                break;
            case OP_TFORCALL:
                /* results land in R[A+3]..R[A+2+C] */
                if (C > 0)
                    validate_req(A + 2 + C < p->maxstack, "generic-for frame A+2+C",
                                 pc, p, A + 2 + C);
                break;
            case OP_LOADNIL:
                validate_req(A + B < p->maxstack, "null range A+B", pc, p, A + B);
                break;
            case OP_CONCAT:
                if (B > 0)
                    validate_req(A + B - 1 < p->maxstack, "concat range A+B-1",
                                 pc, p, A + B - 1);
                break;
            case OP_CALL: case OP_TAILCALL:
                if (B > 0)
                    validate_req(A + B - 1 < p->maxstack, "call window A+B-1",
                                 pc, p, A + B - 1);
                break;
            case OP_RETURN:
                if (B > 0)
                    validate_req(A + B - 2 < p->maxstack, "return window A+B-2",
                                 pc, p, A + B - 2);
                break;
            case OP_SETLIST: {
                /* R[A][...] := R[A+1] .. R[A+vB] (vB == 0 means "up to top",
                ** in which case no fixed register range is implied). */
                int vB = getvB(ins);
                if (vB > 0)
                    validate_req(A + vB < p->maxstack, "list range A+vB", pc, p, A + vB);
                break;
            }
            case OP_JMP: {
                int tgt = pc + 1 + getsJ(ins);
                validate_req(tgt >= 0 && tgt <= p->ncode, "jump target", pc, p, tgt);
                break;
            }
            default:
                break;
        }
    }

    for (int i = 0; i < p->sizep; i++) validate_proto(p->p[i]);
}

/* Mark every instruction that can be reached by a jump / branch. */
static void mark_jump_targets(Proto *p, int *is_target) {
    for (int pc = 0; pc < p->ncode; pc++) is_target[pc] = 0;
    for (int pc = 0; pc < p->ncode; pc++) {
        Instruction ins = p->code[pc];
        switch (getop(ins)) {
            case OP_JMP: {
                int tgt = pc + 1 + getsJ(ins);
                if (tgt >= 0 && tgt < p->ncode) is_target[tgt] = 1;
                break;
            }
            case OP_LFALSESKIP:
                /* sets R[A] to false and skips the next instruction */
                if (pc + 2 < p->ncode) is_target[pc + 2] = 1;
                break;
            case OP_EQ: case OP_LT: case OP_LE:
            case OP_EQK: case OP_EQI: case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
            case OP_TEST: case OP_TESTSET:
                /* the instruction after a test is a jump; skipping the jump
                ** lands on pc+2, and taking it lands on the jump target,
                ** which is handled by the OP_JMP case above. */
                if (pc + 2 < p->ncode) is_target[pc + 2] = 1;
                break;
            /* Loops use the *unsigned* Bx: 'pc -= Bx' / 'pc += Bx (+1)'. */
            case OP_FORLOOP: {
                int tgt = pc + 1 - getBx(ins);
                if (tgt >= 0 && tgt < p->ncode) is_target[tgt] = 1;
                break;
            }
            case OP_FORPREP: {
                int tgt = pc + 1 + getBx(ins) + 1;
                if (tgt >= 0 && tgt < p->ncode) is_target[tgt] = 1;
                break;
            }
            case OP_TFORPREP: {
                int tgt = pc + 1 + getBx(ins);
                if (tgt >= 0 && tgt < p->ncode) is_target[tgt] = 1;
                break;
            }
            case OP_TFORLOOP: {
                int tgt = pc + 1 - getBx(ins);
                if (tgt >= 0 && tgt < p->ncode) is_target[tgt] = 1;
                break;
            }
        }
    }
    is_target[0] = 1;
}

/* Number of consecutive registers starting at R[A] that 'op' overwrites,
** or -1 when the count is only known at run time. */
static int writes_count (int op, Instruction ins) {
    int B = getB(ins), C = getC(ins);
    switch (op) {
        case OP_LOADNIL: return B + 1;
        case OP_SELF:    return 2;
        case OP_CALL:    return (C == 0) ? -1 : C - 1;
        case OP_VARARG:  return (C == 0) ? -1 : C - 1;
        default: break;
    }
    switch (op) {
        case OP_MOVE: case OP_LOADI: case OP_LOADF: case OP_LOADK: case OP_LOADKX:
        case OP_LOADFALSE: case OP_LFALSESKIP: case OP_LOADTRUE:
        case OP_GETUPVAL: case OP_GETTABUP: case OP_GETTABLE: case OP_GETI:
        case OP_GETFIELD: case OP_NEWTABLE:
        case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_MODK:
        case OP_POWK: case OP_DIVK: case OP_IDIVK: case OP_BANDK: case OP_BORK:
        case OP_BXORK: case OP_SHLI: case OP_SHRI:
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_MOD: case OP_POW:
        case OP_DIV: case OP_IDIV: case OP_BAND: case OP_BOR: case OP_BXOR:
        case OP_SHL: case OP_SHR:
        case OP_UNM: case OP_BNOT: case OP_NOT: case OP_LEN: case OP_CONCAT:
        case OP_TESTSET: case OP_CLOSURE: case OP_GETVARG:
            return 1;
        default:
            return 0;
    }
}

/* -------------------------------------------------------------------------
** Function emission
** ------------------------------------------------------------------------- */

static void emit_body(Emitter *E, Proto *root, Proto *p, FnCtx *FX) {
    int maxstack = p->maxstack;
    if (maxstack < 1) maxstack = 1;
    int nparams  = p->numparams;
    int isvahid  = (p->flag & PF_VAHID) != 0;
    int isvatab  = (p->flag & PF_VATAB) != 0;
    /* Frame size actually materialised on the stack.  It is >= maxstack:
    ** the extra slots are holes that break the "slot - b - 1 == register"
    ** relation an analyst would otherwise rely on. */
    int fsz      = FX ? FX->fsz : maxstack;

    /* Registers declared "to be closed" (local x <close> = ...).  OP_TBC
    ** marks them; OP_CLOSE runs their __close in reverse order. */
    int *istbc = (int*)calloc((size_t)maxstack, sizeof(int));
    int ntbc = 0;
    for (int i = 0; i < p->ncode; i++) {
        if (getop(p->code[i]) == OP_TBC) {
            int r = getA(p->code[i]);
            if (r >= 0 && r < maxstack && !istbc[r]) { istbc[r] = 1; ntbc++; }
        }
    }

    E_reset(E);

    /* Registers captured by nested closures.  Their authoritative copy lives
    ** in a shared cell (see l2c_box* in the preamble); the register slot is
    ** only a cache that is refreshed before every instruction. */
    if (p->ncap > 0) {
        int first = 1;
        emit(E, "  static const int l2c_caps[] = {");
        for (int r = 0; r < maxstack; r++)
            if (p->capreg[r]) { emit(E, "%s%d", first ? "" : ", ", r); first = 0; }
        emit(E, "};\n");
    }

    /* Diversification macros.  Everything below is written against the short
    ** names b / top / ne / R() / l2c_* / KP; these defines re-point them at
    ** per-function locals, the per-function register permutation, per-proto
    ** helper copies and this function's constant-pool upvalue. */
    if (FX) {
        emit(E, "  int %s = 0, %s, %s = 0;\n", FX->vb, FX->vt, FX->vn);
        emit(E, "#define b   %s\n", FX->vb);
        emit(E, "#define top %s\n", FX->vt);
        emit(E, "#define ne  %s\n", FX->vn);
        /* The permutation table covers exactly [0, fsz).  Indices at or above
        ** fsz do occur -- a VARARG with C==0 or an open CALL/SETLIST/RETURN
        ** window can address registers the compiler never counted -- so those
        ** fall back to the identity layout, which keeps R() total and
        ** consistent for the open region. */
        if (FX->mode == 1)
            emit(E, "#define R(r) (b + (((r) < %d) ? ((r) ^ %d) : (r)) + 1)\n",
                 fsz, FX->xmask);
        else
            emit(E, "#define R(r) (b + (((r) < %d) ? %s[r] : (r)) + 1)\n",
                 fsz, FX->mapname);
        if (FX->need_loop)
            emit(E, "#define l2c_forprep %s\n#define l2c_forloop %s\n",
                 FX->h_prep, FX->h_loop);
        if (FX->need_box)
            emit(E, "#define l2c_boxget %s\n#define l2c_boxsync %s\n"
                    "#define l2c_boxpull %s\n#define l2c_boxpullall %s\n",
                 FX->h_bget, FX->h_bsync, FX->h_bpull, FX->h_ball);
        if (FX->need_varg)
            emit(E, "#define l2c_tointegerns %s\n", FX->h_vidx);
        if (FX->mode == 0) {
            emit(E, "  static const unsigned char %s[] = {", FX->mapname);
            for (int r = 0; r < fsz; r++)
                emit(E, "%s%d", r ? "," : "", r < maxstack ? FX->perm[r] : r);
            emit(E, "};\n");
        }
    } else {
        emit(E, "  int b = 0, top, ne = 0;\n");
        emit(E, "#define R(r) (b + (r) + 1)\n");
    }
    /* The constant pool is always the last upvalue, after the ones the
    ** bytecode itself declares, so it can never collide with GETUPVAL. */
    emit(E, "#define KP lua_upvalueindex(%d)\n", p->nupvalues + 1);
    emit(E, "  (void)ne;\n");
    emit(E, "  luaL_checkstack(L, %d + 24, \"l2c\");\n", fsz);

    if (isvahid) {
        /* Hidden varargs: the VM moves the fixed parameters above the extra
        ** arguments so that the varargs live just below the frame.  Mimic
        ** that by rotating [fixed..., extra...] into [extra..., fixed...]. */
        emit(E, "  { int _i, _n = lua_gettop(L) - %d; if (_n < 0) _n = 0; ne = _n;\n",
             nparams);
        emit(E, "    if (_n > 0) {\n");
        emit(E, "      luaL_checkstack(L, _n + %d + 24, \"l2c\");\n", fsz);
        emit(E, "      for (_i = 0; _i < %d; _i++) lua_pushvalue(L, 1 + _i);\n", nparams);
        emit(E, "      for (_i = 0; _i < %d; _i++) lua_remove(L, 1);\n", nparams);
        emit(E, "      b = _n;\n");
        emit(E, "    } }\n");
    } else if (isvatab) {
        /* Vararg table: build {1=v1, ..., n=count} into R[numparams]. */
        emit(E, "  { int _i, _n = lua_gettop(L) - %d; if (_n < 0) _n = 0; ne = _n;\n",
             nparams);
        emit(E, "    lua_createtable(L, _n, 1);\n");
        emit(E, "    for (_i = 0; _i < _n; _i++) { "
                "lua_pushvalue(L, %d + 1 + _i); lua_rawseti(L, -2, _i + 1); }\n",
             nparams);
        emit(E, "    lua_pushinteger(L, _n); lua_setfield(L, -2, \"n\");\n");
        emit(E, "    for (_i = 0; _i < _n; _i++) lua_remove(L, %d + 1);\n", nparams);
        emit(E, "  }\n");
    }

    /* Captured registers live in shared cells; the table holding them sits at
    ** stack slot 1, below the register frame, so that the 'lua_settop' calls
    ** used for Lua calls (which never go below b+1) cannot clobber it. */
    if (p->ncap > 0)
        emit(E, "  lua_createtable(L, %d, 0); lua_insert(L, 1); b = b + 1;\n", p->ncap);

    emit(E, "  lua_settop(L, b + %d);\n", fsz);
    emit(E, "  top = b + %d;\n", nparams + (isvatab ? 2 : 1));

    int *is_target = (int*)calloc((size_t)p->ncode + 2, sizeof(int));
    mark_jump_targets(p, is_target);
    /* The state machine needs a state to start in, so the entry instruction
    ** must own a label like any other dispatch target. */
    if (g_flatten) is_target[0] = 1;
    for (int pc = 0; pc < p->ncode; pc++)
        if (is_target[pc]) (void)E_LABEL(E, pc);

    for (int pc = 0; pc < p->ncode; pc++) {
        Instruction ins = p->code[pc];
        int op = getop(ins);
        int A  = getA(ins);
        int B  = getB(ins);
        int C  = getC(ins);
        int k  = getk(ins);
        int vB = getvB(ins);
        int vC = getvC(ins);
        int Bx = getBx(ins);
        int sBx = getsBx(ins);
        int Ax = getAx(ins);
        int sJ = getsJ(ins);

        if (is_target[pc]) {
            int id = E->labels[pc];
            if (id) emit(E, "  L_%d: ;  /* pc=%d */\n", id, pc);
            else    emit(E, "  /* pc=%d (entry) */\n", pc);
        }

        if (g_annotate)
            emit(E, "  /* [%d] %s */ ", pc, OP_NAMES[op]);
        if (p->ncap > 0) {
            /* captured registers may have been written through a cell by a
            ** nested closure: refresh them from the cell before use */
            const char *map = (FX && FX->mode == 0) ? FX->mapname : "(const unsigned char *)0";
            emit(E, "l2c_boxpullall(L, 1, b, l2c_caps, %d, %s, %d); ",
                 p->ncap, map, (FX && FX->mode == 1) ? FX->xmask : 0);
        }

        switch (op) {
            case OP_MOVE:
                emit(E, "lua_pushvalue(L, R(%d)); lua_replace(L, R(%d));", B, A);
                break;
            case OP_LOADI:
                emit(E, "lua_pushinteger(L, %dLL); lua_replace(L, R(%d));", sBx, A);
                break;
            case OP_LOADF:
                emit(E, "lua_pushnumber(L, (lua_Number)%d); lua_replace(L, R(%d));", sBx, A);
                break;
            case OP_LOADK:
                emit_pushk(E, p, Bx);
                emit(E, "; lua_replace(L, R(%d));", A);
                break;
            case OP_LOADKX: {
                if (pc + 1 >= p->ncode || getop(p->code[pc+1]) != OP_EXTRAARG) {
                    emit(E, "/* bad LOADKX */"); break;
                }
                int kidx = getAx(p->code[++pc]);
                emit_pushk(E, p, kidx);
                emit(E, "; lua_replace(L, R(%d));", A);
                break;
            }
            case OP_LOADFALSE:
                emit(E, "lua_pushboolean(L, 0); lua_replace(L, R(%d));", A);
                break;
            case OP_LFALSESKIP:
                emit(E, "lua_pushboolean(L, 0); lua_replace(L, R(%d)); goto L_%d;",
                     A, E_LABEL(E, pc + 2));
                break;
            case OP_LOADTRUE:
                emit(E, "lua_pushboolean(L, 1); lua_replace(L, R(%d));", A);
                break;
            case OP_LOADNIL:
                emit(E, "{ int _i; for (_i = 0; _i <= %d; _i++) "
                        "{ lua_pushnil(L); lua_replace(L, R(%d + _i)); } }", B, A);
                break;
            case OP_GETUPVAL:
                if (p->upbox && p->upbox[B])
                    emit(E, "lua_geti(L, lua_upvalueindex(%d), 1); lua_replace(L, R(%d));",
                         B + 1, A);
                else
                    emit(E, "lua_pushvalue(L, lua_upvalueindex(%d)); lua_replace(L, R(%d));",
                         B + 1, A);
                break;
            case OP_SETUPVAL:
                if (p->upbox && p->upbox[B])
                    emit(E, "lua_pushvalue(L, R(%d)); lua_seti(L, lua_upvalueindex(%d), 1);",
                         A, B + 1);
                else
                    emit(E, "lua_pushvalue(L, R(%d)); lua_replace(L, lua_upvalueindex(%d));",
                         A, B + 1);
                break;
            case OP_GETTABUP: { /* R[A] := UpValue[B][K[C]:string] */
                int boxed = (p->upbox && p->upbox[B]);
                if (boxed)      /* shared cell: unbox into R[A], then index it */
                    emit(E, "lua_geti(L, lua_upvalueindex(%d), 1); "
                            "lua_replace(L, R(%d)); ", B + 1, A);
                if (!emit_kkey(E, p, C)) { emit(E, "/* GETTABUP: bad key */"); break; }
                if (boxed) emit(E, "; lua_gettable(L, R(%d)); lua_replace(L, R(%d));", A, A);
                else       emit(E, "; lua_gettable(L, lua_upvalueindex(%d)); "
                                   "lua_replace(L, R(%d));", B + 1, A);
                break;
            }
            case OP_GETTABLE:   /* R[A] := R[B][R[C]] */
                emit(E, "lua_pushvalue(L, R(%d)); lua_gettable(L, R(%d)); "
                        "lua_replace(L, R(%d));", C, B, A);
                break;
            case OP_GETI:       /* R[A] := R[B][C] */
                emit(E, "lua_geti(L, R(%d), %d); lua_replace(L, R(%d));", B, C, A);
                break;
            case OP_GETFIELD:   /* R[A] := R[B][K[C]:string] */
                if (!emit_kkey(E, p, C)) { emit(E, "/* GETFIELD: bad key */"); break; }
                emit(E, "; lua_gettable(L, R(%d)); lua_replace(L, R(%d));", B, A);
                break;
            case OP_SETTABUP: { /* UpValue[A][K[B]:string] := RK(C) */
                int boxed = (p->upbox && p->upbox[A]);
                if (boxed)      /* shared cell: push the real table first */
                    emit(E, "lua_geti(L, lua_upvalueindex(%d), 1); ", A + 1);
                if (!emit_kkey(E, p, B)) { emit(E, "/* SETTABUP: bad key */"); break; }
                emit(E, "; ");
                emit_pushrk(E, p, C, k);
                if (boxed) emit(E, "; lua_settable(L, -3); lua_pop(L, 1);");
                else       emit(E, "; lua_settable(L, lua_upvalueindex(%d));", A + 1);
                break;
            }
            case OP_SETTABLE:   /* R[A][R[B]] := RK(C) */
                emit(E, "lua_pushvalue(L, R(%d)); ", B);
                emit_pushrk(E, p, C, k);
                emit(E, "; lua_settable(L, R(%d));", A);
                break;
            case OP_SETI:       /* R[A][B] := RK(C) */
                emit_pushrk(E, p, C, k);
                emit(E, "; lua_seti(L, R(%d), %d);", A, B);
                break;
            case OP_SETFIELD:   /* R[A][K[B]:string] := RK(C) */
                if (!emit_kkey(E, p, B)) { emit(E, "/* SETFIELD: bad key */"); break; }
                emit(E, "; ");
                emit_pushrk(E, p, C, k);
                emit(E, "; lua_settable(L, R(%d));", A);
                break;
            case OP_NEWTABLE: {
                int hash = vB > 0 ? (1 << (vB - 1)) : 0;
                int arr  = vC;
                if (k && pc + 1 < p->ncode && getop(p->code[pc+1]) == OP_EXTRAARG)
                    arr += (int)getAx(p->code[++pc]) * (MAXARG_vC + 1);
                emit(E, "lua_createtable(L, %d, %d); lua_replace(L, R(%d));", arr, hash, A);
                break;
            }
            case OP_SELF:       /* R[A+1] := R[B]; R[A] := R[B][K[C]] */
                emit(E, "lua_pushvalue(L, R(%d)); lua_replace(L, R(%d)); ", B, A + 1);
                if (!emit_kkey(E, p, C)) { emit(E, "/* SELF: bad key */"); break; }
                emit(E, "; lua_gettable(L, R(%d)); lua_replace(L, R(%d));", B, A);
                break;
            case OP_ADDI: {     /* R[A] := R[B] + sC */
                int sC = C - OFFSET_sC;
                emit(E, "lua_pushvalue(L, R(%d)); lua_pushinteger(L, %dLL); "
                        "lua_arith(L, LUA_OPADD); lua_replace(L, R(%d));", B, sC, A);
                break;
            }
            case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_MODK: case OP_POWK:
            case OP_DIVK: case OP_IDIVK: case OP_BANDK: case OP_BORK: case OP_BXORK:
                emit(E, "lua_pushvalue(L, R(%d)); ", B);
                emit_pushk(E, p, C);
                emit(E, "; lua_arith(L, %s); lua_replace(L, R(%d));",
                     arith_op_str(op), A);
                break;
            case OP_SHLI: {     /* R[A] := sC << R[B] */
                int sC = C - OFFSET_sC;
                emit(E, "lua_pushinteger(L, %dLL); lua_pushvalue(L, R(%d)); "
                        "lua_arith(L, LUA_OPSHL); lua_replace(L, R(%d));", sC, B, A);
                break;
            }
            case OP_SHRI: {     /* R[A] := R[B] >> sC */
                int sC = C - OFFSET_sC;
                emit(E, "lua_pushvalue(L, R(%d)); lua_pushinteger(L, %dLL); "
                        "lua_arith(L, LUA_OPSHR); lua_replace(L, R(%d));", B, sC, A);
                break;
            }
            case OP_ADD: case OP_SUB: case OP_MUL: case OP_MOD: case OP_POW:
            case OP_DIV: case OP_IDIV: case OP_BAND: case OP_BOR: case OP_BXOR:
            case OP_SHL: case OP_SHR:
                emit(E, "lua_pushvalue(L, R(%d)); lua_pushvalue(L, R(%d)); "
                        "lua_arith(L, %s); lua_replace(L, R(%d));",
                     B, C, arith_op_str(op), A);
                break;
            case OP_MMBIN: case OP_MMBINI: case OP_MMBINK:
                /* lua_arith already routes through metamethods. */
                emit(E, "/* MMBIN no-op */");
                break;
            case OP_UNM:
                emit(E, "lua_pushvalue(L, R(%d)); lua_arith(L, LUA_OPUNM); "
                        "lua_replace(L, R(%d));", B, A);
                break;
            case OP_BNOT:
                emit(E, "lua_pushvalue(L, R(%d)); lua_arith(L, LUA_OPBNOT); "
                        "lua_replace(L, R(%d));", B, A);
                break;
            case OP_NOT:
                emit(E, "lua_pushboolean(L, !lua_toboolean(L, R(%d))); "
                        "lua_replace(L, R(%d));", B, A);
                break;
            case OP_LEN:
                emit(E, "lua_len(L, R(%d)); lua_replace(L, R(%d));", B, A);
                break;
            case OP_CONCAT: {   /* R[A] := R[A] .. ... .. R[A+B-1] */
                emit(E, "{ int _i; for (_i = 0; _i < %d; _i++) "
                        "lua_pushvalue(L, R(%d + _i)); "
                        "lua_concat(L, %d); lua_replace(L, R(%d)); }", B, A, B, A);
                break;
            }
            case OP_CLOSE: {
                /* Close every to-be-closed slot at or above R[A]; luaF_close
                ** walks the list from the top down, so one call suffices. */
                if (B == 0 && ntbc > 0) {   /* B set => dead placeholder */
                    int low = -1;
                    for (int r = A; r < maxstack; r++)
                        if (istbc[r]) { low = r; break; }
                    if (low >= 0) emit(E, "lua_closeslot(L, R(%d));", low);
                    else          emit(E, "/* CLOSE R(%d): no tbc slot */", A);
                } else {
                    emit(E, "/* CLOSE R(%d) */", A);
                }
                break;
            }
            case OP_TBC:
                if (A < maxstack) {
                    istbc[A] = 1;
                    emit(E, "lua_toclose(L, R(%d));", A);
                } else {
                    emit(E, "/* TBC R(%d) out of frame */", A);
                }
                break;
            case OP_JMP: {
                int tgt = pc + 1 + sJ;
                if (tgt < 0 || tgt > p->ncode) { emit(E, "/* JMP out of range */"); break; }
                emit(E, "goto L_%d;", E_LABEL(E, tgt));
                break;
            }
            /* Comparisons: the VM executes the following OP_JMP when the
            ** condition equals k, and skips it otherwise.  Emitting
            ** "goto <pc+2>" for the mismatch case lets the JMP instruction
            ** fall through naturally for the match case. */
            case OP_EQ: case OP_LT: case OP_LE: {
                const char *cop = (op == OP_EQ) ? "LUA_OPEQ"
                                : (op == OP_LT) ? "LUA_OPLT" : "LUA_OPLE";
                emit(E, "if (lua_compare(L, R(%d), R(%d), %s) != %d) goto L_%d;",
                     A, B, cop, k, E_LABEL(E, pc + 2));
                break;
            }
            case OP_EQK: {      /* raw equality against K[B] */
                emit_pushk(E, p, B);
                emit(E, "; if (lua_rawequal(L, R(%d), -1) != %d) { lua_pop(L, 1); goto L_%d; } "
                        "lua_pop(L, 1);", A, k, E_LABEL(E, pc + 2));
                break;
            }
            /* Comparison against a signed immediate sB (stored as B-OFFSET_sC).
            ** Field C is the VM's 'isf' flag: the literal was written as a
            ** float (e.g. 'x < 2.0'), and op_orderI hands that float -- not an
            ** integer -- to a __lt/__le metamethod, so the pushed type matters.
            ** GTI/GEI put the immediate on the left, which the VM expresses as
            ** the mirrored LTI/LEI. */
            case OP_EQI: case OP_LTI: case OP_LEI: {
                int sB = B - OFFSET_sC;
                const char *cop = (op == OP_EQI) ? "LUA_OPEQ"
                                : (op == OP_LTI) ? "LUA_OPLT" : "LUA_OPLE";
                emit(E, (C ? "lua_pushnumber(L, (lua_Number)%d); "
                           : "lua_pushinteger(L, %dLL); "), sB);
                emit(E, "if (lua_compare(L, R(%d), -1, %s) != %d) { lua_pop(L, 1); goto L_%d; } "
                        "lua_pop(L, 1);", A, cop, k, E_LABEL(E, pc + 2));
                break;
            }
            case OP_GTI: case OP_GEI: {   /* immediate is the left operand */
                int sB = B - OFFSET_sC;
                const char *cop = (op == OP_GTI) ? "LUA_OPLT" : "LUA_OPLE";
                emit(E, (C ? "lua_pushnumber(L, (lua_Number)%d); "
                           : "lua_pushinteger(L, %dLL); "), sB);
                emit(E, "if (lua_compare(L, -1, R(%d), %s) != %d) { lua_pop(L, 1); goto L_%d; } "
                        "lua_pop(L, 1);", A, cop, k, E_LABEL(E, pc + 2));
                break;
            }
            case OP_TEST:
                emit(E, "if (lua_toboolean(L, R(%d)) != %d) goto L_%d;",
                     A, k, E_LABEL(E, pc + 2));
                break;
            case OP_TESTSET:
                emit(E, "if ((!lua_toboolean(L, R(%d))) == %d) goto L_%d; "
                        "else { lua_pushvalue(L, R(%d)); lua_replace(L, R(%d)); }",
                     B, k, E_LABEL(E, pc + 2), B, A);
                break;
            case OP_CALL: {
                /* With a permuted register layout R(A)..R(A+B-1) is no longer
                ** contiguous, and lua_call needs func+args on top of the
                ** stack.  So the call window is materialised above the frame
                ** and the results are scattered back into R(A..).
                **
                ** The frame is only a *lower* bound on the live region: an
                ** open window (CALL/TAILCALL with B==0) reads registers the
                ** compiler never counted, because a VARARG with C==0 can fill
                ** an unbounded number of them.  _hi therefore tracks the
                ** highest live slot and must never shrink below it, or the
                ** arguments would be truncated before they are copied. */
                emit(E, "{ int _i, _j, _nr, _nb = ");
                if (B != 0) emit(E, "%d; ", B);
                else        emit(E, "top - b - %d - 1; if (_nb < 0) _nb = 0; ", A);
                emit(E, "int _hi = b + %d, _t; ", fsz);
                emit(E, "if ((_t = b + %d + _nb) > _hi) _hi = _t; ", A);
                emit(E, "luaL_checkstack(L, _nb + 8, \"l2c\"); lua_settop(L, _hi); ");
                emit(E, "for (_i = 0; _i < _nb; _i++) lua_pushvalue(L, R(%d + _i)); ", A);
                emit(E, "lua_call(L, _nb - 1, ");
                if (C == 0) emit(E, "LUA_MULTRET); _nr = lua_gettop(L) - _hi; ");
                else        emit(E, "%d); _nr = %d; ", C - 1, C - 1);
                emit(E, "for (_j = 0; _j < _nr; _j++) "
                        "lua_pushvalue(L, _hi + 1 + _j); ");
                emit(E, "for (_j = _nr - 1; _j >= 0; _j--) "
                        "lua_replace(L, R(%d + _j)); ", A);
                emit(E, "if ((_t = b + %d + _nr) > _hi) _hi = _t; ", A);
                emit(E, "lua_settop(L, _hi); ");
                if (C == 0) emit(E, "top = b + %d + _nr + 1; }", A);
                else        emit(E, "top = b + %d; }", A + C);
                break;
            }
            case OP_TAILCALL: {
                emit(E, "{ int _i, _nb = ");
                if (B != 0) emit(E, "%d; ", B);
                else        emit(E, "top - b - %d - 1; if (_nb < 0) _nb = 0; ", A);
                emit(E, "int _hi = b + %d, _t; ", fsz);
                emit(E, "if ((_t = b + %d + _nb) > _hi) _hi = _t; ", A);
                emit(E, "luaL_checkstack(L, _nb + 8, \"l2c\"); lua_settop(L, _hi); ");
                emit(E, "for (_i = 0; _i < _nb; _i++) lua_pushvalue(L, R(%d + _i)); ", A);
                emit(E, "lua_call(L, _nb - 1, LUA_MULTRET); "
                        "return lua_gettop(L) - _hi; }");
                break;
            }
            case OP_RETURN: {
                if (B != 0) {
                    int n = B - 1;
                    if (n == 0) emit(E, "return 0;");
                    else emit(E, "{ int _i; for (_i = 0; _i < %d; _i++) "
                                 "lua_pushvalue(L, R(%d + _i)); return %d; }", n, A, n);
                } else {
                    emit(E, "{ int _i, _n = top - b - %d - 1; if (_n < 0) _n = 0; "
                            "for (_i = 0; _i < _n; _i++) lua_pushvalue(L, R(%d + _i)); "
                            "return _n; }", A, A);
                }
                break;
            }
            case OP_RETURN0:
                emit(E, "return 0;");
                break;
            case OP_RETURN1:
                emit(E, "lua_pushvalue(L, R(%d)); return 1;", A);
                break;
            case OP_FORPREP:
                /* The three control slots are logically adjacent but not
                ** physically adjacent once R() is a permutation, so the
                ** helper takes them as three separate stack indices. */
                emit(E, "if (l2c_forprep(L, R(%d), R(%d), R(%d))) goto L_%d;",
                     A, A + 1, A + 2, E_LABEL(E, pc + 2 + Bx));
                break;
            case OP_FORLOOP:
                emit(E, "if (l2c_forloop(L, R(%d), R(%d), R(%d))) goto L_%d;",
                     A, A + 1, A + 2, E_LABEL(E, pc + 1 - Bx));
                break;
            case OP_TFORPREP:
                /* The generic-for control block is R[A]..R[A+3]:
                **   R[A]=iterator, R[A+1]=state, R[A+2]=control, R[A+3]=closing.
                ** Swap control and closing, then mark the closing value (which
                ** the swap moved into R[A+2]) as to-be-closed, exactly as the
                ** VM's luaF_newtbcupval(ra+2) does.  Without this the 4th
                ** value of 'for x in f, s, ctl, close do' never runs __close.
                ** lua_toclose is a no-op for false/nil, so a plain 'for k,v in
                ** pairs(t)' stays unaffected; a non-nil value without __close
                ** raises the same error the VM raises. */
                if (A + 2 < maxstack) istbc[A + 2] = 1;
                emit(E, "{ if (lua_gettop(L) < b + %d) lua_settop(L, b + %d); "
                        "lua_pushvalue(L, R(%d + 3)); lua_pushvalue(L, R(%d + 2)); "
                        "lua_replace(L, R(%d + 3)); lua_replace(L, R(%d + 2)); "
                        "lua_toclose(L, R(%d + 2)); "
                        "goto L_%d; }",
                     fsz, fsz, A, A, A, A, A, E_LABEL(E, pc + 1 + Bx));
                break;
            case OP_TFORCALL:
                /* call R[A](R[A+1], R[A+3]); the C results go to R[A+3..] */
                emit(E, "{ int _i; lua_settop(L, b + %d); "
                        "lua_pushvalue(L, R(%d)); lua_pushvalue(L, R(%d + 1)); "
                        "lua_pushvalue(L, R(%d + 3)); lua_call(L, 2, %d); "
                        "for (_i = 0; _i < %d; _i++) "
                        "lua_pushvalue(L, b + %d + 1 + _i); "
                        "for (_i = %d - 1; _i >= 0; _i--) "
                        "lua_replace(L, R(%d + 3 + _i)); "
                        "lua_settop(L, b + %d); }",
                     fsz, A, A, A, C, C, fsz, C, A, fsz);
                break;
            case OP_TFORLOOP:
                emit(E, "if (!lua_isnil(L, R(%d + 3))) goto L_%d;", A, E_LABEL(E, pc + 1 - Bx));
                break;
            case OP_SETLIST: {
                /* R[A+i] -> t[vC + i] for i = 1..n  (vC is the *last* index
                ** already stored, so the first new element goes at vC+1). */
                int n = vB;
                int base_idx = vC;
                if (k && pc + 1 < p->ncode && getop(p->code[pc+1]) == OP_EXTRAARG)
                    base_idx += (int)getAx(p->code[++pc]) * (MAXARG_vC + 1);
                if (n == 0)
                    emit(E, "{ int _i, _n = top - b - %d - 2; if (_n < 0) _n = 0; "
                            "for (_i = 1; _i <= _n; _i++) { "
                            "lua_pushvalue(L, R(%d + _i)); "
                            "lua_seti(L, R(%d), %d + _i); } }",
                         A, A, A, base_idx);
                else
                    emit(E, "{ int _i; for (_i = 1; _i <= %d; _i++) { "
                            "lua_pushvalue(L, R(%d + _i)); "
                            "lua_seti(L, R(%d), %d + _i); } }",
                         n, A, A, base_idx);
                break;
            }
            case OP_CLOSURE: {
                Proto *sub = p->p[Bx];
                int sub_id = proto_id(root, sub);
                int nup = sub->nupvalues;
                for (int ui = 0; ui < nup; ui++) {
                    UpvalDesc *u = &sub->upvalues[ui];
                    if (u->instack)
                        emit(E, "l2c_boxget(L, 1, %d, R(%d)); ", u->idx + 1, u->idx);
                    else
                        emit(E, "lua_pushvalue(L, lua_upvalueindex(%d)); ", u->idx + 1);
                }
                /* the constant pool is handed down as one extra upvalue */
                emit(E, "lua_pushvalue(L, KP); "
                        "lua_pushcclosure(L, %s, %d); lua_replace(L, R(%d));",
                     g_fnames[sub_id], nup + 1, A);
                break;
            }
            case OP_VARARG: {   /* R[A], ..., R[A+C-2] = varargs */
                /* Source: the vararg table when VATAB, else the hidden
                ** arguments, which sit immediately below the frame. */
                emit(E, "{ int _i, _w = %d, _u; ", C - 1);
                if (isvatab) {
                    emit(E, "if (_w < 0) { _w = ne; _u = _w; } "
                            "else _u = (ne > _w) ? _w : ne; "
                            "lua_pushvalue(L, R(%d)); "
                            "for (_i = 0; _i < _u; _i++) { "
                            "  lua_rawgeti(L, -1, _i + 1); lua_replace(L, R(%d + _i)); "
                            "} lua_pop(L, 1); ", nparams, A);
                } else {
                    emit(E, "if (_w < 0) { _w = ne; _u = _w; } "
                            "else _u = (ne > _w) ? _w : ne; ");
                }
                /* A vararg block can extend past maxstacksize; make sure the
                ** destination registers really exist. */
                emit(E, "{ int _nd = b + %d + _w; "
                        "if (_nd > lua_gettop(L)) { "
                        "  luaL_checkstack(L, _nd - lua_gettop(L), \"l2c\"); "
                        "  lua_settop(L, _nd); } } ", A);
                if (!isvatab)
                    emit(E, "for (_i = 0; _i < _u; _i++) { "
                            "  lua_pushvalue(L, b - ne + 1 + _i); "
                            "  lua_replace(L, R(%d + _i)); } ", A);
                emit(E, "for (_i = _u; _i < _w; _i++) { lua_pushnil(L); "
                        "lua_replace(L, R(%d + _i)); } ", A);
                if (C == 0) emit(E, "top = b + %d + ne + 1; ", A);
                emit(E, "}");
                break;
            }
            case OP_GETVARG: {  /* R[A] := vararg[R[C]] (or "n") */
                /* The VM reads the key with tointegerns(), so an integer or
                ** an integral *float* selects a vararg slot while everything
                ** else -- including a numeric string -- does not. */
                emit(E, "{ lua_Integer _k; if (l2c_tointegerns(L, R(%d), &_k)) { "
                        "if ((lua_Integer)1 <= _k && _k <= (lua_Integer)ne) { "
                        "lua_pushvalue(L, b - ne + _k); lua_replace(L, R(%d)); } "
                        "else { lua_pushnil(L); lua_replace(L, R(%d)); } } "
                        "else if (lua_type(L, R(%d)) == LUA_TSTRING && "
                        "strcmp(lua_tostring(L, R(%d)), \"n\") == 0) "
                        "{ lua_pushinteger(L, ne); lua_replace(L, R(%d)); } "
                        "else { lua_pushnil(L); lua_replace(L, R(%d)); } }",
                     C, A, A, C, C, A, A);
                break;
            }
            case OP_ERRNNIL:    /* error when R[A] is *not* nil */
                if (Bx > 0 && Bx <= p->sizek && is_kstr(p->k[Bx-1].tag)) {
                    emit(E, "if (!lua_isnil(L, R(%d))) luaL_error(L, "
                            "\"global '%%s' already defined\", ", A);
                    (void)emit_kstr(E, p, Bx - 1);
                    emit(E, ");");
                } else {
                    /* luaG_errnnil() falls back to the literal name "?" when the
                    ** global name constant cannot be encoded (Bx == 0). */
                    emit(E, "if (!lua_isnil(L, R(%d))) "
                            "luaL_error(L, \"global '?' already defined\");", A);
                }
                break;
            case OP_VARARGPREP:
                emit(E, "/* VARARGPREP handled in the prologue */");
                break;
            case OP_EXTRAARG:
                emit(E, "/* EXTRAARG %d */", Ax);
                break;
            default:
                /* validate_proto() rejects unknown opcodes, so reaching here
                ** means the emitter and the validator have drifted apart:
                ** fail loudly rather than emit a silently-wrong translation. */
                fatal("unhandled opcode %s (%d) at instruction %d",
                      (op >= 0 && op < NUM_OPCODES) ? OP_NAMES[op] : "?", op, pc);
                break;
        }
        /* Keep the shared cells of captured registers in sync. */
        if (p->ncap > 0) {
            int wn = writes_count(op, ins);
            if (wn > 0)
                for (int r = A; r < A + wn && r < maxstack; r++)
                    if (p->capreg[r])
                        emit(E, " l2c_boxsync(L, 1, %d, R(%d));", r + 1, r);
        }
        emit(E, "\n");
    }
    /* Tear the diversification macros down again: the next function defines
    ** its own (different) ones. */
    emit(E, "#undef b\n#undef top\n#undef ne\n#undef R\n#undef KP\n");
    if (FX) {
        if (FX->need_loop)
            emit(E, "#undef l2c_forprep\n#undef l2c_forloop\n");
        if (FX->need_box)
            emit(E, "#undef l2c_boxget\n#undef l2c_boxsync\n"
                    "#undef l2c_boxpull\n#undef l2c_boxpullall\n");
    }
    emit(E, "  return 0;\n");
    free(is_target);
    free(istbc);
}

/* -------------------------------------------------------------------------
** Runtime support emitted into every generated file
** ------------------------------------------------------------------------- */
static void emit_preamble(FILE *out, const char *in_path) {
    fprintf(out,
        "/* Generated by luac2c from %s.  Do not edit by hand. */\n"
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <string.h>\n"
        "#include <math.h>\n"
        "#include <stdint.h>\n"
        "#include <lua.h>\n"
        "#include <lualib.h>\n"
        "#include <lauxlib.h>\n\n",
        in_path);

    if (g_indirect) {
        int n = L2C_NGAPI;
        const char *t = g_api_tag;

        fprintf(out,
            "/* No Lua entry point is called by name anywhere below.  Every call\n"
            "** goes through %s_t[..].m<k>; the table is decoded once at start-up\n"
            "** under a key taken from a load-time address, so a static dump of\n"
            "** .data maps no call site onto a symbol. */\n"
            "typedef union {\n", t);
        for (int i = 0; i < n; i++)
            fprintf(out, "  __typeof__(&(%s)) m%d;\n", g_api_names[i], i);
        fprintf(out,
            "} %s_u;\n"
            "static %s_u %s_t[%d];\n"
            "static char %s_k[24];\n"
            "static void %s_init (void) {\n"
            "  intptr_t k = (intptr_t)(uintptr_t)%s_k;\n",
            t, t, t, g_api_ntab, t, t, t);
        for (int i = 0; i < n; i++) {
            unsigned long long kk = g_api_k64[i];
            fprintf(out,
                "  %s_t[%u].m%d = (__typeof__(&(%s)))((intptr_t)&%s"
                " ^ (k ^ (intptr_t)0x%016llXULL));\n",
                t, g_api_slot[i], i, g_api_names[i], g_api_names[i], kk);
        }
        fprintf(out, "}\n");
        for (int i = 0; i < n; i++) {
            unsigned long long kk = g_api_k64[i];
            fprintf(out,
                "#undef %s\n"
                "#define %s(...)  ((__typeof__(%s_t[%u].m%d))((intptr_t)"
                "%s_t[%u].m%d ^ ((intptr_t)(uintptr_t)%s_k"
                " ^ (intptr_t)0x%016llXULL)))(__VA_ARGS__)\n",
                g_api_names[i], g_api_names[i], t, g_api_slot[i], i,
                t, g_api_slot[i], i, t, kk);
        }
        fprintf(out, "\n");
    }

    fprintf(out,
        "/* R(r) is defined separately inside every function: register layout\n"
        "** is a per-function permutation rather than the identity map. */\n\n");
}

/* Emit the run-time helpers needed by one function.  Each proto gets its own
** copy under its own names, so spotting the helper in one function tells you
** nothing about the others. */
static void emit_helpers(FILE *out, FnCtx *C) {
    if (C->need_box) {
        fprintf(out,
        "/* Shared cells for captured registers; 'boxes' is the table at\n"
        "** stack slot 1 and cells are keyed by reg+1. */\n"
        "static void %s (lua_State *L, int boxes, int key, int slot) {\n"
        "  lua_rawgeti(L, boxes, key);\n"
        "  if (lua_isnil(L, -1)) {\n"
        "    lua_pop(L, 1);\n"
        "    lua_createtable(L, 1, 0);\n"
        "    lua_pushvalue(L, slot);\n"
        "    lua_rawseti(L, -2, 1);\n"
        "    lua_pushvalue(L, -1);\n"
        "    lua_rawseti(L, boxes, key);\n"
        "  }\n"
        "}\n\n", C->h_bget);

        fprintf(out,
        "static void %s (lua_State *L, int boxes, int key, int slot) {\n"
        "  lua_rawgeti(L, boxes, key);\n"
        "  if (!lua_isnil(L, -1)) {\n"
        "    lua_pushvalue(L, slot);\n"
        "    lua_rawseti(L, -2, 1);\n"
        "  }\n"
        "  lua_pop(L, 1);\n"
        "}\n\n", C->h_bsync);

        fprintf(out,
        "/* Reverse direction: a nested closure may have written the cell, so\n"
        "** refresh the cached register from it before the value is used. */\n"
        "static void %s (lua_State *L, int boxes, int key, int slot) {\n"
        "  lua_rawgeti(L, boxes, key);\n"
        "  if (!lua_isnil(L, -1)) {\n"
        "    lua_rawgeti(L, -1, 1);\n"
        "    lua_replace(L, slot);\n"
        "  }\n"
        "  lua_pop(L, 1);\n"
        "}\n\n", C->h_bpull);

        fprintf(out,
        "static void %s (lua_State *L, int boxes, int base, const int *regs,\n"
        "                           int n, const unsigned char *map, int xm) {\n"
        "  int i;\n"
        "  for (i = 0; i < n; i++) {\n"
        "    int r = regs[i];\n"
        "    %s(L, boxes, r + 1, base + (map ? (int)map[r] : (r ^ xm)) + 1);\n"
        "  }\n"
        "}\n\n", C->h_ball, C->h_bpull);
    }

    if (C->need_varg) {
        fprintf(out,
        "/* Mirror of the VM's 'tointegerns': an index is usable as a vararg\n"
        "** slot number only if it is an integer, or a float holding an exact\n"
        "** integer value.  A numeric string is NOT accepted (unlike\n"
        "** lua_tointegerx, which would coerce \"2\" to 2). */\n"
        "static int %s (lua_State *L, int idx, lua_Integer *out) {\n"
        "  if (lua_isinteger(L, idx)) { *out = lua_tointeger(L, idx); return 1; }\n"
        "  if (lua_type(L, idx) == LUA_TNUMBER) {\n"
        "    lua_Number n = lua_tonumber(L, idx);\n"
        "    lua_Integer i;\n"
        "    if (n != n) return 0;  /* NaN */\n"
        "    if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0))\n"
        "      return 0;  /* out of lua_Integer range */\n"
        "    i = (lua_Integer)n;\n"
        "    if ((lua_Number)i == n) { *out = i; return 1; }\n"
        "  }\n"
        "  return 0;\n"
        "}\n\n", C->h_vidx);
    }

    if (C->need_loop) {
        fprintf(out,
        "/* Mirror of the VM's 'forlimit': returns 1 when the loop body must\n"
        "** be skipped, otherwise stores the (integer) limit in *p. */\n"
        "static int %s (lua_State *L, int idx, lua_Integer init,\n"
        "                         lua_Integer *p, lua_Integer step) {\n"
        "  if (lua_type(L, idx) == LUA_TNUMBER) {\n"
        "    if (lua_isinteger(L, idx)) {\n"
        "      *p = lua_tointeger(L, idx);\n"
        "    } else {\n"
        "      lua_Number flim = lua_tonumber(L, idx);\n"
        "      lua_Number f = (step < 0) ? ceil(flim) : floor(flim);\n"
        "      if (f >= -9223372036854775808.0 && f < 9223372036854775808.0)\n"
        "        *p = (lua_Integer)f;\n"
        "      else if (flim > 0) { if (step < 0) return 1; *p = LUA_MAXINTEGER; }\n"
        "      else                { if (step > 0) return 1; *p = LUA_MININTEGER; }\n"
        "    }\n"
        "  }\n"
        "  else luaL_error(L, \"'for' limit must be a number\");\n"
        "  return (step > 0 ? init > *p : init < *p);\n"
        "}\n\n", C->h_prep_lim);

        fprintf(out,
        "/* Mirror of 'forprep'.  ri/rl/rs are the stack slots holding the\n"
        "** initial value, the limit and the step.  They are passed in\n"
        "** separately because R() is a per-function permutation, so the\n"
        "** three logical registers are not physically adjacent.\n"
        "** Returns 1 when the loop must be skipped. */\n"
        "static int %s (lua_State *L, int ri, int rl, int rs) {\n"
        "  if (lua_isinteger(L, ri) && lua_isinteger(L, rs)) {\n"
        "    lua_Integer init = lua_tointeger(L, ri);\n"
        "    lua_Integer step = lua_tointeger(L, rs);\n"
        "    lua_Integer limit;\n"
        "    lua_Unsigned count;\n"
        "    if (step == 0) luaL_error(L, \"'for' step is zero\");\n"
        "    if (%s(L, rl, init, &limit, step)) return 1;\n"
        "    if (step > 0) {\n"
        "      count = (lua_Unsigned)limit - (lua_Unsigned)init;\n"
        "      if (step != 1) count /= (lua_Unsigned)step;\n"
        "    } else {\n"
        "      count = (lua_Unsigned)init - (lua_Unsigned)limit;\n"
        "      count /= (lua_Unsigned)(-(step + 1)) + 1u;\n"
        "    }\n"
        "    lua_pushinteger(L, (lua_Integer)count); lua_replace(L, ri);\n"
        "    lua_pushinteger(L, step);               lua_replace(L, rl);\n"
        "    lua_pushinteger(L, init);               lua_replace(L, rs);\n"
        "  }\n"
        "  else {\n"
        "    lua_Number init, limit, step;\n"
        "    int ok1, ok2, ok3;\n"
        "    limit = lua_tonumberx(L, rl, &ok1);\n"
        "    step  = lua_tonumberx(L, rs, &ok2);\n"
        "    init  = lua_tonumberx(L, ri, &ok3);\n"
        "    if (!ok1) luaL_error(L, \"'for' limit must be a number\");\n"
        "    if (!ok2) luaL_error(L, \"'for' step must be a number\");\n"
        "    if (!ok3) luaL_error(L, \"'for' initial value must be a number\");\n"
        "    if (step == 0) luaL_error(L, \"'for' step is zero\");\n"
        "    if (step > 0 ? (limit < init) : (init < limit)) return 1;\n"
        "    lua_pushnumber(L, limit); lua_replace(L, ri);\n"
        "    lua_pushnumber(L, step);  lua_replace(L, rl);\n"
        "    lua_pushnumber(L, init);  lua_replace(L, rs);\n"
        "  }\n"
        "  return 0;\n"
        "}\n\n", C->h_prep, C->h_prep_lim);

        fprintf(out,
        "/* One step of a numeric 'for'; returns 1 when the loop continues.\n"
        "** After forprep, rc = count/limit, rs = step, ridx = index. */\n"
        "static int %s (lua_State *L, int rc, int rs, int ridx) {\n"
        "  if (lua_isinteger(L, rs)) {\n"
        "    lua_Integer step = lua_tointeger(L, rs);\n"
        "    lua_Integer idx  = lua_tointeger(L, ridx);\n"
        "    lua_Unsigned count = (lua_Unsigned)lua_tointeger(L, rc);\n"
        "    if (count > 0) {\n"
        "      lua_pushinteger(L, (lua_Integer)(count - 1)); lua_replace(L, rc);\n"
        "      lua_pushinteger(L, idx + step);               lua_replace(L, ridx);\n"
        "      return 1;\n"
        "    }\n"
        "  }\n"
        "  else {\n"
        "    lua_Number step = lua_tonumber(L, rs);\n"
        "    lua_Number limit = lua_tonumber(L, rc);\n"
        "    lua_Number idx = lua_tonumber(L, ridx) + step;\n"
        "    if (step > 0 ? (idx <= limit) : (limit <= idx)) {\n"
        "      lua_pushnumber(L, idx); lua_replace(L, ridx);\n"
        "      return 1;\n"
        "    }\n"
        "  }\n"
        "  return 0;\n"
        "}\n\n", C->h_loop);
    }
}

/* Emit the constant pool: an encoded blob plus the decoder that turns it into
** a Lua table, so no string or number from the original chunk survives as a
** literal in the object file. */
static void emit_pool(FILE *out) {
    if (g_pool_n == 0) {                 /* nothing to hide; keep it minimal */
        fprintf(out, "static void l2c_%s (lua_State *L) { lua_createtable(L, 0, 0); }\n\n",
                g_kbuild);
        return;
    }
    fprintf(out, "static const unsigned char l2c_%s[] = {\n", g_kblob);
    for (int i = 0; i < g_pool_n; i++) {
        PoolEnt *e = &g_pool_tab[i];
        unsigned char raw[16];
        int len = 0, tag = 0;
        if (e->tag == KINT) {
            long long v = e->i; memcpy(raw, &v, 8); len = 8; tag = 1;
        } else if (e->tag == KFLT) {
            double v = e->n;    memcpy(raw, &v, 8); len = 8; tag = 2;
        } else {
            len = (int)strlen(e->s); tag = 3;
        }
        fprintf(out, "  %d,%d,%d,", tag, len & 0xff, (len >> 8) & 0xff);
        for (int j = 0; j < len; j++) {
            unsigned char b = (tag == 3) ? (unsigned char)e->s[j] : raw[j];
            fprintf(out, " %u,", (unsigned)(b ^ pool_xor(i, j)));
        }
        fprintf(out, "\n");
    }
    fprintf(out, "};\n\n");

    fprintf(out,
        "static unsigned char l2c_%s (int i, int j) {\n"
        "  unsigned x = (%uu ^ %uu)\n"
        "             ^ (unsigned)i * 0x9E3779B9u\n"
        "             ^ (unsigned)j * 0x85EBCA6Bu;\n"
        "  x ^= x >> 15; x *= 0x2545F491u; x ^= x >> 13;\n"
        "  return (unsigned char)(x & 0xffu);\n"
        "}\n\n",
        g_kxor, g_pk1, g_pk2);

    fprintf(out,
        "/* Decode the blob above into a Lua table (indexed from 1). */\n"
        "static void l2c_%s (lua_State *L) {\n"
        "  const unsigned char *p = l2c_%s;\n"
        "  int i, n = %d;\n"
        "  lua_createtable(L, n, 0);\n"
        "  for (i = 0; i < n; i++) {\n"
        "    int tag = *p++;\n"
        "    int len = p[0] | (p[1] << 8);\n"
        "    int j;\n"
        "    p += 2;\n"
        "    if (tag == 3) {\n"
        "      luaL_Buffer b;\n"
        "      luaL_buffinit(L, &b);\n"
        "      for (j = 0; j < len; j++)\n"
        "        luaL_addchar(&b, (char)((unsigned char)p[j] ^ l2c_%s(i, j)));\n"
        "      luaL_pushresult(&b);\n"
        "    } else {\n"
        "      unsigned char raw[8];\n"
        "      for (j = 0; j < 8; j++) raw[j] = (unsigned char)(p[j] ^ l2c_%s(i, j));\n"
        "      if (tag == 1) { lua_Integer v; memcpy(&v, raw, 8); lua_pushinteger(L, v); }\n"
        "      else           { lua_Number  v; memcpy(&v, raw, 8); lua_pushnumber(L, v); }\n"
        "    }\n"
        "    p += len;\n"
        "    lua_rawseti(L, -2, i + 1);\n"
        "  }\n"
        "}\n\n", g_kbuild, g_kblob, g_pool_n, g_kxor, g_kxor);
}

/* ---------------------------------------------------------------------------
** Control-flow flattening
**
** A body is emitted as a flat run of label/instruction pairs, which is easy to
** read and easy to follow.  Rather than teach every opcode handler about a
** dispatcher, one body's text is rewritten afterwards: each block becomes a
** 'case' of a switch on an encoded state, and each 'goto L_<n>' becomes an
** assignment to that state plus a 'break'.  The rewrite is sound because the
** emitted bodies hold three properties, all covered by the regression suite:
**   - transfers are written only as 'goto L_<n>;', and no other construct in a
**     body looks like a label;
**   - no transfer sits inside a 'for' loop, so the inserted 'break' always
**     leaves the switch and never an enclosing loop;
**   - a body contains no 'break' of its own for the inserted one to collide
**     with.
** Fall-through between neighbouring blocks is preserved by giving every case
** an explicit successor state, which also removes the flattened code's most
** obvious tell: a missing transfer.  State values run through st_enc(), an
** affine bijection, so the case labels are neither consecutive nor related to
** the program counters they stand for.
** ------------------------------------------------------------------------- */

static const char *flat_state_of(unsigned id);

/* Is `p` the start of a "  L_<n>: ;" label line?  On success store the id and
** set *end just past the newline. */
static int flat_label(const char *p, const char *limit, unsigned *id,
                      const char **end) {
    if (limit - p < 6) return 0;
    if (p[0] != ' ' || p[1] != ' ' || p[2] != 'L' || p[3] != '_') return 0;
    const char *q = p + 4;
    unsigned v = 0; int any = 0;
    while (q < limit && *q >= '0' && *q <= '9') {
        v = v * 10u + (unsigned)(*q - '0'); q++; any = 1;
    }
    if (!any) return 0;
    if (limit - q < 3 || q[0] != ':' || q[1] != ' ' || q[2] != ';') return 0;
    *id = v;
    const char *e = q;
    while (e < limit && *e != '\n') e++;
    if (e < limit) e++;
    *end = e;
    return 1;
}

/* First label line at or after `from`, or NULL. */
static const char *flat_find_label(const char *from, const char *limit) {
    unsigned id; const char *e;
    for (const char *p = from; p < limit; p++) {
        if (p > from && p[-1] != '\n') continue;
        if (flat_label(p, limit, &id, &e)) return p;
    }
    return NULL;
}

/* Copy one block, turning every 'goto L_<n>;' into a state assignment.  The
** braces keep the replacement a single statement, so it stays valid where the
** original jump was the body of an 'if'. */
static void flat_block(FILE *dst, const char *seg, size_t n, const char *stv) {
    size_t i = 0;
    while (i < n) {
        size_t j = i; const char *p = NULL;
        while (j + 7 <= n) {
            if (seg[j] == 'g' && memcmp(seg + j, "goto L_", 7) == 0) {
                p = seg + j; break;
            }
            j++;
        }
        if (!p) { fwrite(seg + i, 1, n - i, dst); return; }
        fwrite(seg + i, 1, (size_t)(p - seg) - i, dst);
        const char *q = p + 7;
        unsigned id = 0; int any = 0;
        while (q < seg + n && *q >= '0' && *q <= '9') {
            id = id * 10u + (unsigned)(*q - '0'); q++; any = 1;
        }
        if (!any || q >= seg + n || *q != ';') {
            fwrite(p, 1, 7, dst);            /* not a transfer: copy it as is */
            i = (size_t)(p - seg) + 7;
            continue;
        }
        fprintf(dst, "{ %s = %s; break; }", stv, flat_state_of(id));
        i = (size_t)(q - seg) + 1;
    }
}

/* Encoded state for a label id, as text.  A tiny ring of buffers is enough:
** at most three states are live at any point during the rewrite. */
static const char *flat_state_of(unsigned id) {
    static char ring[4][16];
    static int  next = 0;
    char *b = ring[next = (next + 1) & 3];
    snprintf(b, sizeof ring[0], "%uu", st_enc((int)id));
    return b;
}

/* Modular inverse of an odd 32-bit value.  The affine state map is a bijection
** exactly because this inverse exists; it is what lets the dispatcher recover
** a block number from a state without a lookup table. */
static unsigned modinv32(unsigned a) {
    unsigned x = 1u;
    for (int i = 0; i < 40; i++) x *= 2u - a * x;
    return x;
}

/* Form 1: keep every block in place and dispatch with a switch over the
** encoded state. */
static void flat_switch(FILE *body, const char *buf, size_t n,
                        const char *start, const char *limit,
                        const char *kw, const char *fn) {
    char stv[128], exit_st[16];
    snprintf(stv, sizeof stv, "%s_s", fn);
    snprintf(exit_st, sizeof exit_st, "%uu", st_enc(0x7FFFFFFF));
    unsigned id0; const char *e0;
    flat_label(start, limit, &id0, &e0);
    (void)n;

    fprintf(body, "%sint %s(lua_State *L) {\n", kw, fn);
    fwrite(buf, 1, (size_t)(start - buf), body);
    fprintf(body, "  unsigned int %s = %s;\n  for (;;) {\n  switch (%s) {\n",
            stv, flat_state_of(id0), stv);
    const char *p = start;
    for (;;) {
        unsigned id; const char *adv;
        if (!flat_label(p, limit, &id, &adv)) break;
        const char *nx = flat_find_label(adv, limit);
        const char *seg_end = nx ? nx : limit;
        fprintf(body, "  case %s: ;\n", flat_state_of(id));
        flat_block(body, adv, (size_t)(seg_end - adv), stv);
        if (nx) {
            unsigned nid; const char *nxe;
            if (flat_label(nx, limit, &nid, &nxe))
                fprintf(body, "  { %s = %s; break; }\n", stv, flat_state_of(nid));
        } else {
            fprintf(body, "  { %s = %s; break; }\n", stv, exit_st);
        }
        if (!nx) break;
        p = nx;
    }
    fprintf(body, "  default: return 0;\n  }\n  }\n}\n\n");
}

static int flat_index_of(const unsigned *bid, int nb, unsigned id) {
    for (int i = 0; i < nb; i++) if (bid[i] == id) return i;
    return -1;
}

/* Rewrite one block for the split form: a jump becomes 'return <state>;', and
** every original 'return <n>;' -- which leaves the Lua C function -- becomes
** "record the result count, then leave the machine too".  The two are told
** apart because generated state values always carry a 'u' suffix. */
static void flat_split_block(FILE *dst, const char *seg, size_t n,
                             const unsigned *bid, int nb, unsigned exit_st) {
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n) {
            if (seg[j] == 'g' && j + 7 <= n &&
                memcmp(seg + j, "goto L_", 7) == 0) break;
            if (seg[j] == 'r' && j + 7 <= n &&
                memcmp(seg + j, "return ", 7) == 0) {
                if (j == 0 || !((seg[j-1] >= 'a' && seg[j-1] <= 'z') ||
                                (seg[j-1] >= 'A' && seg[j-1] <= 'Z') ||
                                (seg[j-1] >= '0' && seg[j-1] <= '9') ||
                                 seg[j-1] == '_')) break;
            }
            j++;
        }
        if (j >= n) { fwrite(seg + i, 1, n - i, dst); return; }
        fwrite(seg + i, 1, j - i, dst);
        if (seg[j] == 'g') {
            const char *q = seg + j + 7;
            unsigned id = 0; int any = 0;
            while (q < seg + n && *q >= '0' && *q <= '9') {
                id = id * 10u + (unsigned)(*q - '0'); q++; any = 1;
            }
            if (!any || q >= seg + n || *q != ';') {
                fwrite(seg + j, 1, 7, dst);
                i = j + 7;
                continue;
            }
            int idx = flat_index_of(bid, nb, id);
            fprintf(dst, "return %uu;", st_enc(idx < 0 ? nb : idx));
            i = (size_t)(q - seg) + 1;
        } else {
            const char *q = seg + j + 7, *arg = q;
            int depth = 0;
            while (q < seg + n) {
                char c = *q;
                if (c == '(') depth++;
                else if (c == ')') depth--;
                else if (depth == 0 && (c == ';' || c == '{' || c == '}')) break;
                q++;
            }
            if (q >= seg + n || *q != ';') {
                fwrite(seg + j, 1, 7, dst);
                i = j + 7;
                continue;
            }
            fwrite("{ *ro = (", 1, 9, dst);
            fwrite(arg, 1, (size_t)(q - arg), dst);
            fprintf(dst, "); return %uu; }", exit_st);
            i = (size_t)(q - seg) + 1;
        }
    }
}

#define FLAT_MAXB   8192    /* blocks in one body            */
#define FLAT_MAXDEF 64      /* #define / static-const lines  */

/* Form 2: one small static function per block, reached through a table of
** function pointers.  The register frame stays in the dispatcher and is handed
** to each block by address, so a block is a plain function of (L, frame,
** result count) and nothing else. */
static void flat_split(FILE *body, FILE *pre, const char *buf, size_t n,
                       const char *start, const char *limit,
                       const char *kw, const char *fn) {
    static const char *lp[FLAT_MAXB];
    static const char *bstart[FLAT_MAXB];
    static unsigned    bid[FLAT_MAXB];
    int nb = 0;
    const char *p = start;
    while (p && p < limit && nb < FLAT_MAXB) {
        unsigned id; const char *a;
        if (!flat_label(p, limit, &id, &a)) break;
        lp[nb] = p; bid[nb] = id; bstart[nb] = a; nb++;
        p = flat_find_label(a, limit);
    }
    if (nb < 2) { flat_switch(body, buf, n, start, limit, kw, fn); return; }

    /* Harvest what the blocks need from the prologue: the three register
    ** names, the macro definitions, and any file-visible tables. */
    char rn[3][72];
    char dnm[FLAT_MAXDEF][64];
    rn[0][0] = rn[1][0] = rn[2][0] = 0;
    memset(dnm, 0, sizeof dnm);
    const char *dl[FLAT_MAXDEF]; size_t dlen[FLAT_MAXDEF]; int nd = 0;
    const char *cl[FLAT_MAXDEF]; size_t clen[FLAT_MAXDEF]; int nc = 0;
    const char *q = buf;
    while (q < start) {
        const char *le = q;
        while (le < start && *le != '\n') le++;
        const char *lx = (le < start) ? le + 1 : le;
        size_t len = (size_t)(lx - q);
        if (len >= 6 && memcmp(q, "  int ", 6) == 0) {
            const char *s = q + 6;
            for (int k = 0; k < 3; k++) {
                while (s < lx && (*s == ' ' || *s == ',' || *s == '=' ||
                                  *s == ';' || (*s >= '0' && *s <= '9'))) s++;
                const char *st = s;
                while (s < lx && ((*s >= 'a' && *s <= 'z') ||
                                  (*s >= 'A' && *s <= 'Z') ||
                                  (*s >= '0' && *s <= '9') || *s == '_')) s++;
                size_t l = (size_t)(s - st);
                if (!l || l >= sizeof rn[0]) break;
                memcpy(rn[k], st, l); rn[k][l] = 0;
            }
        } else if (len >= 9 && memcmp(q, "#define ", 8) == 0 && nd < FLAT_MAXDEF) {
            dl[nd] = q; dlen[nd] = len; nd++;
        } else if (len >= 15 && memcmp(q, "  static const ", 15) == 0 &&
                   nc < FLAT_MAXDEF) {
            cl[nc] = q; clen[nc] = len; nc++;
        }
        q = lx;
    }
    if (!rn[0][0] || !rn[1][0] || !rn[2][0]) {
        flat_switch(body, buf, n, start, limit, kw, fn); return;
    }

    unsigned exit_st = st_enc(nb);
    unsigned ainv    = modinv32(g_st_a);

    fprintf(pre, "/* One static function per basic block, reached through %s_d. */\n"
                 "#undef b\n#define b   (*rb)\n"
                 "#undef top\n#define top (*rt)\n"
                 "#undef ne\n#define ne  (*rn)\n", fn);
    for (int i = 0; i < nd; i++) {
        const char *d = dl[i]; size_t l = dlen[i];
        if (l > 9  && memcmp(d, "#define b", 9)   == 0 && (d[9] ==' '||d[9] =='\t')) continue;
        if (l > 11 && memcmp(d, "#define top", 11) == 0 && (d[11]==' '||d[11]=='\t')) continue;
        if (l > 10 && memcmp(d, "#define ne", 10) == 0 && (d[10]==' '||d[10]=='\t')) continue;
        const char *nm = d + 8; size_t nl = 0;
        while (8 + nl < l && nm[nl] != ' ' && nm[nl] != '\t' && nm[nl] != '(') nl++;
        if (nl >= sizeof dnm[0]) nl = sizeof dnm[0] - 1;
        memcpy(dnm[i], nm, nl); dnm[i][nl] = 0;
        fputs("#undef ", pre);
        fwrite(nm, 1, nl, pre);
        fputc('\n', pre);
        fwrite(d, 1, l, pre);
    }

    for (int i = 0; i < nb; i++) {
        const char *s  = bstart[i];
        const char *se = (i + 1 < nb) ? lp[i + 1] : limit;
        fprintf(pre, "static unsigned %s_%d (lua_State *L, int *rb, int *rt, "
                     "int *rn, int *ro) {\n", fn, i);
        for (int c = 0; c < nc; c++) fwrite(cl[c], 1, clen[c], pre);
        flat_split_block(pre, s, (size_t)(se - s), bid, nb, exit_st);
        fprintf(pre, "  return %uu;\n}\n\n",
                (i + 1 < nb) ? st_enc(i + 1) : exit_st);
    }

    fprintf(pre, "typedef unsigned (*%s_fp)(lua_State *, int *, int *, int *, int *);\n"
                 "static %s_fp const %s_d[%d] = {", fn, fn, fn, nb);
    for (int i = 0; i < nb; i++)
        fprintf(pre, "%s%s_%d",
                (i == 0) ? "\n  " : ((i % 8) ? ", " : ",\n  "), fn, i);
    fprintf(pre, "\n};\n\n");

    fprintf(body, "%sint %s(lua_State *L) {\n", kw, fn);
    fwrite(buf, 1, (size_t)(start - buf), body);
    fprintf(body,
        "  { unsigned %s_s = %uu; int %s_k, %s_o = 0;\n"
        "    for (;;) {\n"
        "      %s_k = (int)(unsigned)((%s_s - %uu) * %uu);\n"
        "      if (%s_k < 0 || %s_k >= %d) break;\n"
        "      %s_s = %s_d[%s_k](L, &%s, &%s, &%s, &%s_o);\n"
        "    }\n"
        "    return %s_o; }\n"
        "}\n\n",
        fn, st_enc(0), fn, fn,
        fn, fn, g_st_b, ainv,
        fn, fn, nb,
        fn, fn, fn, rn[0], rn[1], rn[2], fn,
        fn);

    /* The prologue's macros are torn down here: the dispatcher closed over
    ** them, and nothing after this function may see them. */
    fprintf(body, "#undef b\n#undef top\n#undef ne\n");
    for (int i = 0; i < nd; i++)
        if (dnm[i][0]) fprintf(body, "#undef %s\n", dnm[i]);
}

/* Append everything `src` holds, from the start, to `dst`. */
static void copy_stream(FILE *dst, FILE *src) {
    char buf[8192];
    size_t got;
    fflush(src);
    if (fseek(src, 0, SEEK_SET) != 0) return;
    while ((got = fread(buf, 1, sizeof buf, src)) > 0)
        fwrite(buf, 1, got, dst);
}

/* Rewrite one function body.  `src` holds exactly what emit_body() produced.
** The rewritten function goes to `body`; when the blocks are split out, their
** definitions and the dispatch table go to `pre`, which the caller has to
** place above the function itself. */
static void flatten_emit(FILE *body, FILE *pre, FILE *src, const char *kw,
                         const char *fn) {
    fflush(src);
    if (fseek(src, 0, SEEK_END) != 0) return;
    long n = ftell(src);
    if (n <= 0 || fseek(src, 0, SEEK_SET) != 0) return;
    char *buf = (char*)malloc((size_t)n + 1);
    if (!buf) return;
    if (fread(buf, 1, (size_t)n, src) != (size_t)n) { free(buf); return; }
    buf[n] = 0;

    const char *limit = buf + n;
    const char *start = flat_find_label(buf, limit);
    unsigned id0; const char *e0;
    if (!start || !flat_label(start, limit, &id0, &e0)) {
        /* Nothing to rewrite: hand the body through unchanged. */
        fprintf(body, "%sint %s(lua_State *L) {\n", kw, fn);
        fwrite(buf, 1, (size_t)n, body);
        fprintf(body, "}\n\n");
        free(buf);
        return;
    }
    if (g_split) flat_split(body, pre, buf, (size_t)n, start, limit, kw, fn);
    else         flat_switch(body, buf, (size_t)n, start, limit, kw, fn);
    free(buf);
}


static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s input.luac [-o output.c] [options]\n"
        "Options:\n"
        "  --seed N        deterministic diversification seed\n"
        "  --static        emit the plain, fully predictable translation\n"
        "  --no-pool       keep string/number constants as C literals\n"
        "  --pool-all      move numbers into the run-time pool as well\n"
        "  --annotate      keep the /* [pc] OPCODE */ markers\n",
        prog);
    exit(1);
}

int main(int argc, char **argv) {
    const char *in_path = NULL;
    const char *out_path = NULL;
    unsigned long long seed = 0;
    int seed_given = 0;   /* distinguish "--seed 0" from no --seed at all */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            out_path = argv[++i];
        } else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
            seed = strtoull(argv[++i], NULL, 0);
            seed_given = 1;
        } else if (strcmp(argv[i], "--static") == 0) {
            g_diversify = 0;
        } else if (strcmp(argv[i], "--no-pool") == 0) {
            g_pool = 0;
        } else if (strcmp(argv[i], "--pool-all") == 0) {
            g_pool = 2;
        } else if (strcmp(argv[i], "--annotate") == 0) {
            g_annotate = 1;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            usage(argv[0]);
        } else {
            in_path = argv[i];
        }
    }
    if (!in_path) usage(argv[0]);
    if (!out_path) out_path = "out.c";
    if (!seed_given) {
        /* No seed requested: --static is the reproducible baseline (pin the
        ** seed so the output is byte-for-byte stable); an interactive run
        ** without --static draws a fresh seed from the clock.  An explicit
        ** "--seed 0" is honoured as 0. */
        if (!g_diversify) seed = 1;
        else seed = (unsigned long long)time(NULL) * 2654435761u
                  ^ (unsigned long long)(uintptr_t)(void*)&seed;
    }
    rng_seed(seed);
    /* --static is the readable, byte-reproducible baseline, so it forces every
    ** static-hardening transform back off; diversify mode turns them on. */
    if (!g_diversify) { g_flatten = 0; g_split = 0; g_indirect = 0; }
    if (g_diversify) {
        g_pk1  = rng_u32();                 /* two shares of the pool key */
        g_pk2  = rng_u32();
        g_st_a = rng_u32() | 1u;            /* odd => bijection mod 2^32  */
        if (g_st_a == 1u) g_st_a = 3u;
        g_st_b = rng_u32();
        if (g_indirect) plan_api_table();
    }
    if (!g_pool) g_pool = 0;

    load_opmodes();

    Reader R = {0};
    R.fp = fopen(in_path, "rb");
    if (!R.fp) { perror(in_path); return 1; }

    loadHeader(&R);
    if (R.err) { fprintf(stderr, "%s\n", R.errmsg); fclose(R.fp); return 1; }

    /* luaU_undump reads the main closure's upvalue count before the proto */
    r_read1(&R);
    if (R.err) { fprintf(stderr, "%s\n", R.errmsg); fclose(R.fp); return 1; }

    Proto *root = proto_new();
    loadFunction(&R, root);
    fclose(R.fp);
    for (int i = 0; i < R.nstr; i++) free(R.strs[i]);
    free(R.strs);
    if (R.err) { fprintf(stderr, "%s\n", R.errmsg); proto_free(root); return 1; }

    compute_captures(root);
    validate_proto(root);   /* abort on anything the emitter cannot index safely */

    FILE *out = fopen(out_path, "w");
    if (!out) { perror(out_path); proto_free(root); return 1; }

    int total = count_nested(root) + 1;
    Proto **list = (Proto**)calloc((size_t)total, sizeof(Proto*));
    int lcount = 0;
    flatten_protos(root, list, &lcount);

    /* Plan every function first: names, register layout and helper copies are
    ** drawn from the seed before anything is emitted. */
    FnCtx *ctx = (FnCtx*)calloc((size_t)lcount, sizeof(FnCtx));
    g_fnames   = (char**)calloc((size_t)lcount, sizeof(char*));
    for (int i = 0; i < lcount; i++) {
        plan_function(&ctx[i], list[i]);
        if (g_diversify) g_fnames[i] = ctx[i].fn;
        else {
            char tmp[32];
            snprintf(tmp, sizeof tmp, "l2c_fn_%d", i);
            g_fnames[i] = xstrdup(tmp);
        }
    }
    g_kblob  = g_diversify ? mkname("kd") : xstrdup("kdata");
    g_kbuild = g_diversify ? mkname("kb") : xstrdup("kbuild");
    g_kxor   = g_diversify ? mkname("kx") : xstrdup("kxor");
    if (g_indirect) g_api_tag = mkname("ax");

    /* The header needs the API tag, so it is written only once every name is
    ** planned.  Nothing above this point has touched the output file. */
    emit_preamble(out, in_path);

    fprintf(out, "static void l2c_%s (lua_State *L);\n\n", g_kbuild);

    for (int i = 0; i < lcount; i++)
        fprintf(out, "%sint %s(lua_State *L);\n", (i == 0) ? "" : "static ", g_fnames[i]);
    fprintf(out, "\n");

    Emitter E = { .out = out, .labels = NULL, .nlabels = 0, .next_label = 0 };

    for (int i = 0; i < lcount; i++) {
        const char *kw = (i == 0) ? "" : "static ";
        /* Helpers are needed whenever the body references them, in both the
        ** diversified and the --static baseline build. */
        if (ctx[i].need_box || ctx[i].need_loop || ctx[i].need_varg)
            emit_helpers(out, &ctx[i]);

        FILE *scr = g_flatten ? tmpfile() : NULL;
        FILE *blk = g_flatten ? tmpfile() : NULL;
        FILE *bod = g_flatten ? tmpfile() : NULL;
        if (scr && blk && bod) {
            /* Let emit_body() write into a scratch file, so the finished body
            ** can be rewritten (and, when splitting, taken apart) before it is
            ** handed on.  The block functions have to precede the function
            ** that dispatches to them, hence the second scratch file. */
            E.out = scr;
            emit_body(&E, root, list[i], &ctx[i]);
            E.out = out;
            flatten_emit(bod, blk, scr, kw, g_fnames[i]);
            copy_stream(out, blk);
            copy_stream(out, bod);
            fclose(scr); fclose(blk); fclose(bod);
        } else {
            if (scr) fclose(scr);
            if (blk) fclose(blk);
            if (bod) fclose(bod);
            emit(&E, "%sint %s(lua_State *L) {\n", kw, g_fnames[i]);
            emit_body(&E, root, list[i], &ctx[i]);
            emit(&E, "}\n\n");
        }
    }

    /* The pool is filled while the bodies are emitted, so it comes last. */
    emit_pool(out);

    /* The main chunk runs protected: an uncaught error is reported the
    ** way the standalone interpreter does (message on stderr, exit 1)
    ** instead of aborting through lua_error on an unprotected call. */
    fprintf(out,
        "static int l2c_report (lua_State *L) {\n"
        "  const char *msg = lua_tostring(L, -1);\n"
        "  if (msg == NULL) msg = \"(error object is not a string)\";\n"
        "  fprintf(stderr, \"lua: %%s\\n\", msg);\n"
        "  return 0;\n"
        "}\n\n");

    char apt_init[64] = "";
    if (g_indirect) snprintf(apt_init, sizeof apt_init, "  %s_init();\n", g_api_tag);

    fprintf(out,
        "int main(int argc, char **argv) {\n"
        "  int status;\n"
        "  (void)argc; (void)argv;\n"
        "%s"
        "  lua_State *L = luaL_newstate();\n"
        "  if (L == NULL) { fprintf(stderr, \"cannot create state\\n\"); return 1; }\n"
        "  luaL_openlibs(L);\n"
        "  lua_pushcclosure(L, l2c_report, 0);\n"
        "  lua_pushglobaltable(L);\n"
        "  l2c_%s(L);\n"                    /* _ENV, then the constant pool */
        "  lua_pushcclosure(L, %s, 2);\n"
        "  status = lua_pcall(L, 0, 0, 1);\n"
        "  if (status != LUA_OK) { lua_close(L); return 1; }\n"
        "  lua_close(L);\n"
        "  return 0;\n"
        "}\n", apt_init, g_kbuild, g_fnames[0]);

    fclose(out);
    free(E.labels);
    for (int i = 0; i < lcount; i++) { free(ctx[i].perm); free(ctx[i].fn); }
    free(ctx);
    proto_free(root);
    free(list);
    return 0;
}
