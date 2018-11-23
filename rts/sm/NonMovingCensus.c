/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2018
 *
 * Non-moving garbage collector and allocator: Accounting census
 *
 * This is a simple space accounting census useful for characterising
 * fragmentation in the nonmoving heap.
 *
 * ---------------------------------------------------------------------------*/

#include "Rts.h"
#include "NonMoving.h"
#include "Trace.h"
#include "NonMovingCensus.h"

struct nonmoving_alloc_census {
    uint32_t n_active_segs;
    uint32_t n_filled_segs;
    uint32_t n_live_blocks;
    uint32_t n_live_words;
};

// N.B. This may miss segments in the event of concurrent mutation (e.g. if a
// mutator retires its current segment to the filled list).
static struct nonmoving_alloc_census
nonmoving_allocator_census(struct nonmoving_allocator *alloc)
{
    struct nonmoving_alloc_census census = {0, 0, 0, 0};

    for (struct nonmoving_segment *seg = alloc->filled;
         seg != NULL;
         seg = seg->link)
    {
        census.n_filled_segs++;
        census.n_live_blocks += nonmoving_segment_block_count(seg);
        unsigned int n = nonmoving_segment_block_count(seg);
        for (unsigned int i=0; i < n; i++) {
            StgClosure *c = (StgClosure *) nonmoving_segment_get_block(seg, i);
            census.n_live_words += closure_sizeW(c);
        }
    }

    for (struct nonmoving_segment *seg = alloc->active;
         seg != NULL;
         seg = seg->link)
    {
        census.n_active_segs++;
        unsigned int n = nonmoving_segment_block_count(seg);
        for (unsigned int i=0; i < n; i++) {
            if (nonmoving_get_mark(seg, i)) {
                StgClosure *c = (StgClosure *) nonmoving_segment_get_block(seg, i);
                census.n_live_words += closure_sizeW(c);
                census.n_live_blocks++;
            }
        }
    }

    for (unsigned int cap=0; cap < n_capabilities; cap++)
    {
        struct nonmoving_segment *seg = alloc->current[cap];
        unsigned int n = nonmoving_segment_block_count(seg);
        for (unsigned int i=0; i < n; i++) {
            if (nonmoving_get_mark(seg, i)) {
                StgClosure *c = (StgClosure *) nonmoving_segment_get_block(seg, i);
                census.n_live_words += closure_sizeW(c);
                census.n_live_blocks++;
            }
        }
    }
    return census;
}

void nonmoving_print_allocator_census()
{
    for (int i=0; i < NONMOVING_ALLOCA_CNT; i++) {
        struct nonmoving_alloc_census census =
            nonmoving_allocator_census(nonmoving_heap.allocators[i]);

        uint32_t blk_size = 1 << (i + NONMOVING_ALLOCA0);
        // We define occupancy as the fraction of space that is used for useful
        // data (that is, live and not slop).
        double occupancy = 100.0 * census.n_live_words * sizeof(W_)
            / (census.n_live_blocks * blk_size);
        if (census.n_live_blocks == 0) occupancy = 100;
        (void) occupancy; // silence warning if !DEBUG
        debugTrace(DEBUG_nonmoving_gc, "Allocator %d (%d bytes - %d bytes): "
                   "%d active segs, %d filled segs, %d live blocks, %d live words "
                   "(%2.1f%% occupancy)",
                   i, 1 << (i + NONMOVING_ALLOCA0 - 1), 1 << (i + NONMOVING_ALLOCA0),
                   census.n_active_segs, census.n_filled_segs, census.n_live_blocks, census.n_live_words,
                   occupancy);
    }
}