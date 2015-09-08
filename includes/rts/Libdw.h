/* ---------------------------------------------------------------------------
 *
 * (c) The GHC Team, 2014-2015
 *
 * Producing DWARF-based stacktraces with libdw.
 *
 * --------------------------------------------------------------------------*/

#ifndef RTS_LIBDW_H
#define RTS_LIBDW_H

// Chunk capacity
// This is rather arbitrary
#define BACKTRACE_CHUNK_SZ 256

/*
 * Note [Chunked stack representation]
 * ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 *
 * Consider the stack,
 *     main                   calls                        (bottom of stack)
 *       func1                which in turn calls
 *         func2              which calls
 *          func3             which calls
 *            func4           which calls
 *              func5         which calls
 *                func6       which calls
 *                  func7     which requests a backtrace   (top of stack)
 *
 * This would produce the Backtrace (using a smaller chunk size of three for
 * illustrative purposes),
 *
 * Backtrace     /----> Chunk         /----> Chunk         /----> Chunk
 * last --------/       next --------/       next --------/       next
 * n_frames=8           n_frames=2           n_frames=3           n_frames=3
 *                      ~~~~~~~~~~           ~~~~~~~~~~           ~~~~~~~~~~
 *                      func1                func4                func7
 *                      main                 func3                func6
 *                                           func2                func5
 *
 */

/* A chunk of code addresses from an execution stack
 *
 * The first address in this list corresponds to the stack frame
 * nearest to the "top" of the stack.
 */
typedef struct BacktraceChunk_ {
    StgWord n_frames;                      // number of frames in this chunk
    struct BacktraceChunk_ *next;          // the chunk following this one
    StgPtr frames[BACKTRACE_CHUNK_SZ];     // the code addresses from the
                                           // frames
} __attribute__((packed)) BacktraceChunk;

/* A chunked list of code addresses from an execution stack
 *
 * This structure is optimized for append operations since we append O(stack
 * depth) times yet typically only traverse the stack trace once. Consequently,
 * the "top" stack frame (that is, the one where we started unwinding) can be
 * found in the last chunk. Yes, this is a bit inconsistent with the ordering
 * within a chunk. See Note [Chunked stack representation] for a depiction.
 */
typedef struct Backtrace_ {
    StgWord n_frames;        // Total number of frames in the backtrace
    BacktraceChunk *last;    // The first chunk of frames (corresponding to the
                             // bottom of the stack)
} Backtrace;

/* Various information describing the location of an address */
typedef struct Location_ {
    const char *object_file;
    const char *function;

    // lineno and colno are only valid if source_file /= NULL
    const char *source_file;
    StgWord32 lineno;
    StgWord32 colno;
} __attribute__((packed)) Location;

#ifdef USE_LIBDW

void backtrace_free(Backtrace *bt);

/* -------------------------------------------------------------------------
 * Helpers for Haskell interface:
 * ------------------------------------------------------------------------*/

/*
 * Use the current capability's libdw context (initializing if necessary)
 * to collect a backtrace.
 */
Backtrace *libdw_cap_get_backtrace(void);

/*
 * Lookup the location of an address using the current capabiliy's libdw
 * context. Returns 0 if successful.
 */
int libdw_cap_lookup_location(StgPtr pc, Location *loc);

/*
 * Free the current capability's libdw context. This is necessary after
 * you have loaded or unloaded a dynamic module.
 */
void libdw_cap_free(void);

#else

INLINE_HEADER Backtrace *libdw_cap_get_backtrace(void) {
    return NULL;
}

INLINE_HEADER void libdw_cap_free(void) { }

INLINE_HEADER void backtrace_free(Backtrace *bt STG_UNUSED) { }

#endif /* USE_LIBDW */

#endif /* RTS_LIBDW_H */
