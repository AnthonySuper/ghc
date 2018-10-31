/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2018
 *
 * Non-moving garbage collector and allocator: Sweep phase
 *
 * ---------------------------------------------------------------------------*/

#include "Rts.h"
#include "NonMovingSweep.h"
#include "NonMoving.h"
#include "NonMovingMark.h" // for nonmoving_is_alive
#include "Capability.h"
#include "GCThread.h" // for GCUtils.h
#include "GCUtils.h"
#include "Storage.h"
#include "Trace.h"
#include "StableName.h"

static struct nonmoving_segment *pop_all_filled_segments(struct nonmoving_allocator *alloc)
{
    while (true) {
        struct nonmoving_segment *head = alloc->filled;
        if (cas((StgVolatilePtr) &alloc->filled, (StgWord) head, (StgWord) NULL) == (StgWord) head)
            return head;
    }
}

void nonmoving_prepare_sweep()
{
    ASSERT(nonmoving_heap.sweep_list == NULL);

    // Move blocks in the allocators' filled lists into sweep_list
    for (int alloc_idx = 0; alloc_idx < NONMOVING_ALLOCA_CNT; alloc_idx++)
    {
        struct nonmoving_allocator *alloc = nonmoving_heap.allocators[alloc_idx];
        struct nonmoving_segment *filled = pop_all_filled_segments(alloc);

        // Link filled to sweep_list
        if (filled) {
            struct nonmoving_segment *filled_head = filled;
            // Find end of filled list
            while (filled->link) {
                filled = filled->link;
            }
            filled->link = nonmoving_heap.sweep_list;
            nonmoving_heap.sweep_list = filled_head;
        }
    }
}

// On which list should a particular segment be placed?
enum sweep_result {
    SEGMENT_FREE,     // segment is empty: place on free list
    SEGMENT_PARTIAL,  // segment is partially filled: place on active list
    SEGMENT_FILLED    // segment is full: place on filled list
};

// Determine which list a marked segment should be placed on and initialize
// next_free indices as appropriate.
GNUC_ATTR_HOT static enum sweep_result
nonmoving_sweep_segment(struct nonmoving_segment *seg)
{
    bool found_free = false;
    bool found_live = false;

    for (nonmoving_block_idx i = 0;
         i < nonmoving_segment_block_count(seg);
         ++i)
    {
        if (seg->bitmap[i]) {
            found_live = true;
        } else if (!found_free) {
            found_free = true;
            seg->next_free = i;
            seg->next_free_snap = i;
            Bdescr((P_)seg)->u.scan = (P_)nonmoving_segment_get_block(seg, i);
        }

        if (found_free && found_live) {
            return SEGMENT_PARTIAL;
        }
    }

    if (found_live) {
        return SEGMENT_FILLED;
    } else {
        ASSERT(seg->next_free == 0);
        ASSERT(seg->next_free_snap == 0);
        return SEGMENT_FREE;
    }
}

#if defined(DEBUG)

void nonmoving_gc_cafs(struct MarkQueue_ *queue)
{
    uint32_t i = 0;
    StgIndStatic *next;

    for (StgIndStatic *caf = debug_caf_list_snapshot;
         caf != (StgIndStatic*) END_OF_CAF_LIST;
         caf = next)
    {
        next = (StgIndStatic*)caf->saved_info;

        const StgInfoTable *info = get_itbl((StgClosure*)caf);
        ASSERT(info->type == IND_STATIC);

        if (lookupHashTable(queue->marked_objects, (StgWord) caf) == NULL) {
            debugTrace(DEBUG_gccafs, "CAF gc'd at 0x%p", caf);
            SET_INFO((StgClosure*)caf, &stg_GCD_CAF_info); // stub it
        } else {
            // CAF is alive, move it back to the debug_caf_list
            ++i;
            debugTrace(DEBUG_gccafs, "CAF alive at 0x%p", caf);
            ACQUIRE_SM_LOCK; // debug_caf_list is global, locked by sm_mutex
            caf->saved_info = (const StgInfoTable*)debug_caf_list;
            debug_caf_list = caf;
            RELEASE_SM_LOCK;
        }
    }

    debugTrace(DEBUG_gccafs, "%d CAFs live", i);
    debug_caf_list_snapshot = (StgIndStatic*)END_OF_CAF_LIST;
}

static void
clear_segment(struct nonmoving_segment* seg)
{
    size_t end = ((size_t)seg) + NONMOVING_SEGMENT_SIZE;
    memset(&seg->bitmap, 0, end - (size_t)&seg->bitmap);
}

static void
clear_segment_free_blocks(struct nonmoving_segment* seg)
{
    unsigned int block_size = nonmoving_segment_block_size(seg);
    for (unsigned int p_idx = 0; p_idx < nonmoving_segment_block_count(seg); ++p_idx) {
        // after mark, so bit not set == dead
        if (nonmoving_get_mark(seg, p_idx) == 0) {
            memset(nonmoving_segment_get_block(seg, p_idx), 0, block_size);
        }
    }
}

#endif

GNUC_ATTR_HOT void nonmoving_sweep(void)
{
    while (nonmoving_heap.sweep_list) {
        struct nonmoving_segment *seg = nonmoving_heap.sweep_list;

        // Pushing the segment to one of the free/active/filled segments
        // updates the link field, so update sweep_list here
        nonmoving_heap.sweep_list = seg->link;

        enum sweep_result ret = nonmoving_sweep_segment(seg);

        switch (ret) {
        case SEGMENT_FREE:
            IF_DEBUG(sanity, clear_segment(seg));
            nonmoving_push_free_segment(seg);
            break;
        case SEGMENT_PARTIAL:
            IF_DEBUG(sanity, clear_segment_free_blocks(seg));
            nonmoving_push_active_segment(seg);
            break;
        case SEGMENT_FILLED:
            nonmoving_push_filled_segment(seg);
            break;
        default:
            barf("nonmoving_sweep: weird sweep return: %d\n", ret);
        }
    }
}

/* N.B. This happens during the pause so we own all capabilities. */
void nonmoving_sweep_mut_lists()
{
    for (uint32_t n = 0; n < n_capabilities; n++) {
        Capability *cap = capabilities[n];
        bdescr *old_mut_list = cap->mut_lists[oldest_gen->no];
        cap->mut_lists[oldest_gen->no] = allocBlockOnNode_sync(cap->node);
        for (bdescr *bd = old_mut_list; bd; bd = bd->link) {
            for (StgPtr p = bd->start; p < bd->free; p++) {
                StgClosure **q = (StgClosure**)p;
                if (nonmoving_is_alive(*q)) {
                    recordMutableCap(*q, cap, oldest_gen->no);
                }
            }
        }
        freeChain(old_mut_list);
    }
}

void nonmoving_sweep_large_objects()
{
    freeChain_lock(nonmoving_large_objects);
    nonmoving_large_objects = nonmoving_marked_large_objects;
    n_nonmoving_large_blocks = n_nonmoving_marked_large_blocks;
    nonmoving_marked_large_objects = NULL;
    n_nonmoving_marked_large_blocks = 0;
}

// Essentially nonmoving_is_alive, but works when the object died in moving
// heap, see nonmoving_sweep_stable_name_table
static bool is_alive(StgClosure *p)
{
    if (!HEAP_ALLOCED_GC(p)) {
        return true;
    }

    bdescr *bd = Bdescr((P_)p);
    if (bd->flags & BF_NONMOVING) {
        return nonmoving_is_alive(p);
    } else {
        return isAlive(p);
    }
}

void nonmoving_sweep_stable_name_table()
{
    // See comments in gcStableTables

    // FIXME: We can't use nonmoving_is_alive here without first using isAlive:
    // a stable name can die during moving heap collection and we can't use
    // nonmoving_is_alive on those objects. Inefficient.

    // TODO: This won't work in concurrent implementation because (1) because
    // the old heap may be reused by the time we reach here (2) concurrent table
    // modifications

    stableNameLock();
    FOR_EACH_STABLE_NAME(
        p, {
            if (p->sn_obj != NULL) {
                if (!is_alive((StgClosure*)p->sn_obj)) {
                    p->sn_obj = NULL; // Just to make an assertion happy
                    freeSnEntry(p);
                } else if (p->addr != NULL) {
                    if (!is_alive((StgClosure*)p->addr)) {
                        p->addr = NULL;
                    }
                }
            }
        });
    stableNameUnlock();
}
