/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2018
 *
 * Non-moving garbage collector and allocator
 *
 * ---------------------------------------------------------------------------*/

#include "Rts.h"
#include "NonMoving.h"

#define NONMOVING_RSET_CHUNK_SIZE 4096 // in bytes

typedef struct {
    StgClosure *p;      // the object to be marked
    StgClosure *origin; // the object where this reference was found
    uint16_t field_n;   // index of the referencing field
} MarkQueueEnt;

typedef struct {
    // linked via the bdescr.link field.
    bdescr *blocks;

    // always equal to blocks->start, avoiding an indirection
    MarkQueueEnt *entries;

    // index of first unused queue entry
    uint32_t head;
} MarkQueue;

#define MARK_QUEUE_BLOCK_ENTRIES (BLOCK_SIZE / sizeof(MarkQueueEnt))

static void mark_queue_push(MarkQueue *restrict q,
                            const StgClosure *p,
                            const StgClosure *origin,
                            unsigned int field_n)
{
    if (q->head == MARK_QUEUE_BLOCK_ENTRIES) {
        bdescr *bd = allocGroup_lock(1);
        bd->link = q->blocks;
        q->blocks = bd;
        q->entries = bd->start;
        q->head = 0;
    }

    MarkQueueEnt *ent = &q->entries[q->head];
    ent->p = p;
    ent->origin = origin;
    ent->field_n = field_n;
    q->head++;
}

// Returns {0,0,0} if queue is empty.
static MarkQueueEnt mark_queue_pop(MarkQueue *restrict q)
{
    if (q->head == 0) {
        q->blocks = q->blocks->link;
        if (q->blocks == NULL) {
            return {0, 0, 0};
        } else {
            bdescr *old_block = b->block;
            q->entries = q->blocks->start;
            q->head = MARK_QUEUE_BLOCK_ENTRIES;
            freeGroup_lock(old_block); // TODO: hold on to a block to avoid repeated allocation/deallocation?
        }
    }

    return q->entries[q->head--];
}

static void init_mark_queue(MarkQueue *q) {
    q->blocks = allocGroup_lock(1);
    q->blocks->link = NULL;
    q->entries = bd->start;
    q->head = 0;
}

/* Prepare to enter the mark phase. Must be done in stop-the-world. */
void nonmoving_prepare_mark()
{
    // The mark list should be empty since we shouldn't be in a GC.
    ASSERT(nonmoving_heap.mark_list == NULL);

    // Move blocks in allocators' filled lists to mark_list and clear their
    // bitmaps
    for (struct nonmoving_allocator *alloc = nonmoving_heap.allocators;
         alloc < nonmoving_heap.allocators[NONMOVING_ALLOCA_CNT];
         alloc++)
    {
        const struct nonmoving_segment *filled = alloc->filled;
        alloc->filled = NULL;
        if (filled == NULL) continue;

        // Walk down filled list, clearing bitmaps and updating snapshot
        // pointers as we go
        struct nonmoving_segment *seg = filled;
        while (true) {
            nonmoving_clear_bitmap(seg);
            seg->next_free_snap = seg->next_free;
            if (seg->link == NULL) {
                // We've reached the end; link into mark_list.
                seg->link = nonmoving_heap.mark_list;
                nonmoving_heap.mark_list = filled;
                break;
            }
            seg = seg->link;
        }
    }
}

/* This is the main mark loop */
GNUC_ATTR_HOT void nonmoving_mark(MarkQueue *queue, const StgClosure *p)
{
    while (p) {
        StgWord tag = GET_CLOSURE_TAG(p);
        p = UNTAG_CLOSURE(p);
        const StgInfoTable *info = get_itbl(p);
        ASSERTM(LOOKS_LIKE_CLOSURE_PTR(q), "invalid closure, info=%p", q->header.info);

        if (!HEAP_ALLOCED_GC(p)) {

        }

        bdescr *bd = Bdescr(p);
        if (bd->flags & BF_NONMOVING) {
            // Mark the block
            struct nonmoving_segment *seg = nonmoving_get_segment(p);
            nonmoving_block_idx block_idx = nonmoving_get_block_idx(p);
            nonmoving_set_mark_bit(seg, block_idx);

        // The object lives outside of the non-moving heap
        } else {
        }

        switch (info->type) {
        case THUNK_STATIC:
            if (info->)
        }
        q->b;
        if (!q->blocks) {
            allocGroup_lock(1)
        }
    }
}