/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2018
 *
 * Non-moving garbage collector and allocator: Mark phase
 *
 * ---------------------------------------------------------------------------*/

#include "Rts.h"
// We call evacuate, which expects the thread-local gc_thread to be valid;
// This is sometimes declared as a register variable therefore it is necessary
// to include the declaration so that the compiler doesn't clobber the register.
#include "NonMovingMark.h"
#include "NonMoving.h"
#include "BlockAlloc.h"  /* for countBlocks */
#include "HeapAlloc.h"
#include "Task.h"
#include "Trace.h"
#include "HeapUtils.h"
#include "Printer.h"
#include "Schedule.h"
#include "Weak.h"
#include "MarkWeak.h"
#include "sm/Storage.h"

static void mark_tso (MarkQueue *queue, StgTSO *tso);
static void mark_stack (MarkQueue *queue, StgStack *stack);
static void mark_PAP_payload (MarkQueue *queue,
                              StgClosure *fun,
                              StgClosure **payload,
                              StgWord size);

// How many Array# entries to add to the mark queue at once?
#define MARK_ARRAY_CHUNK_LENGTH 128

/* Note [Large objects in the non-moving collector]
 * ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 * The nonmoving collector keeps a separate list of its large objects, apart from
 * oldest_gen->large_objects. There are two reasons for this:
 *
 *  1. oldest_gen is mutated by minor collections, which happen concurrently with
 *     marking
 *  2. the non-moving collector needs a consistent picture
 *
 * At the beginning of a major collection, nonmoving_collect takes the objects in
 * oldest_gen->large_objects (which includes all large objects evacuated by the
 * moving collector) and adds them to nonmoving_large_objects. This is the set
 * of large objects that will being collected in the current major GC cycle.
 *
 * As the concurrent mark phase proceeds, the large objects in
 * nonmoving_large_objects that are found to be live are moved to
 * nonmoving_marked_large_objects. During sweep we discard all objects that remain
 * in nonmoving_large_objects and move everything in nonmoving_marked_larged_objects
 * back to nonmoving_large_objects.
 *
 * During minor collections large objects will accumulate on
 * oldest_gen->large_objects, where they will be picked up by the nonmoving
 * collector and moved to nonmoving_large_objects during the next major GC.
 * When this happens the block gets its BF_NONMOVING_SWEEPING flag set to
 * indicate that it is part of the snapshot and consequently should be marked by
 * the nonmoving mark phase..
 */

bdescr *nonmoving_large_objects = NULL;
bdescr *nonmoving_marked_large_objects = NULL;
memcount n_nonmoving_large_blocks = 0;
memcount n_nonmoving_marked_large_blocks = 0;
#if defined(THREADED_RTS)
/* Protects everything above. Furthermore, we only set the BF_MARKED bit of
 * large object blocks when this is held. This ensures that the write barrier
 * (e.g. finish_upd_rem_set_mark) and the collector (mark_closure) don't try to
 * move the same large object to nonmoving_marked_large_objects more than once.
 */
static Mutex nonmoving_large_objects_mutex;
#endif

#if defined(DEBUG)
// TODO (osa): Document
StgIndStatic *debug_caf_list_snapshot = (StgIndStatic*)END_OF_CAF_LIST;
#endif

/* Note [Update remembered set]
 * ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 * The concurrent non-moving collector uses a remembered set to ensure
 * that its marking is consistent with the snapshot invariant defined in
 * the design. This remembered set, known as the update remembered set,
 * records all pointers that have been overwritten since the beginning
 * of the concurrent mark. It is maintained via a write barrier that
 * is enabled whenever a concurrent mark is active.
 *
 * The representation of the update remembered set is the same as that of
 * the mark queue. For efficiency, each capability maintains its own local
 * accumulator of remembered set entries. When a capability fills its
 * accumulator it is linked in to the global remembered set
 * (upd_rem_set_block_list), where it is consumed by the mark phase.
 *
 * The mark phase is responsible for freeing update remembered set block
 * allocations.
 *
 */
static Mutex upd_rem_set_lock;
bdescr *upd_rem_set_block_list = NULL;

#if defined(CONCURRENT_MARK)
/* Used during the mark/sweep phase transition to track how many capabilities
 * have pushed their update remembered sets. Protected by upd_rem_set_lock.
 */
static volatile StgWord upd_rem_set_flush_count = 0;
#endif


/* Signaled by each capability when it has flushed its update remembered set */
static Condition upd_rem_set_flushed_cond;

/* Indicates to mutators that the write barrier must be respected. Set while
 * concurrent mark is running.
 */
bool nonmoving_write_barrier_enabled = false;

/* Used to provide the current mark queue to the young generation
 * collector for scavenging.
 */
MarkQueue *current_mark_queue = NULL;

/* Initialise update remembered set data structures */
void nonmoving_mark_init_upd_rem_set() {
    initMutex(&upd_rem_set_lock);
    initCondition(&upd_rem_set_flushed_cond);
#if defined(THREADED_RTS)
    initMutex(&nonmoving_large_objects_mutex);
#endif
}

/* Transfers the given capability's update-remembered set to the global
 * remembered set.
 */
static void nonmoving_add_upd_rem_set_blocks(MarkQueue *rset)
{
    if (mark_queue_is_empty(rset)) return;

    // find the tail of the queue
    bdescr *start = rset->blocks;
    bdescr *end = start;
    while (end->link != NULL)
        end = end->link;

    // add the blocks to the global remembered set
    ACQUIRE_LOCK(&upd_rem_set_lock);
    end->link = upd_rem_set_block_list;
    upd_rem_set_block_list = start;
    RELEASE_LOCK(&upd_rem_set_lock);

    // Reset remembered set
    ACQUIRE_SM_LOCK;
    init_mark_queue(rset);
    RELEASE_SM_LOCK;
}

#if defined(CONCURRENT_MARK)
/* Called by capabilities to flush their update remembered sets when
 * synchronising with the non-moving collector as it transitions from mark to
 * sweep phase.
 */
void nonmoving_flush_cap_upd_rem_set_blocks(Capability *cap)
{
    if (! cap->upd_rem_set_syncd) {
        debugTrace(DEBUG_nonmoving_gc, "Capability %d flushing update remembered set", cap->no);
        traceConcUpdRemSetFlush(cap);
        nonmoving_add_upd_rem_set_blocks(&cap->upd_rem_set.queue);
        atomic_inc(&upd_rem_set_flush_count, 1);
        cap->upd_rem_set_syncd = true;
        signalCondition(&upd_rem_set_flushed_cond);
        // After this mutation will remain suspended until nonmoving_finish_flush
        // releases its capabilities.
    }
}

/* Request that all capabilities flush their update remembered sets and suspend
 * execution until the further notice.
 */
void nonmoving_begin_flush(Task *task)
{
    debugTrace(DEBUG_nonmoving_gc, "Starting update remembered set flush...");
    traceConcSyncBegin();
    for (unsigned int i = 0; i < n_capabilities; i++) {
        capabilities[i]->upd_rem_set_syncd = false;
    }
    upd_rem_set_flush_count = 0;
    stopAllCapabilitiesWith(NULL, task, SYNC_FLUSH_UPD_REM_SET);

    // XXX: We may have been given a capability via releaseCapability (i.e. a
    // task suspended due to a foreign call) in which case our requestSync
    // logic won't have been hit. Make sure that everyone so far has flushed.
    // Ideally we want to mark asynchronously with syncing.
    for (unsigned int i = 0; i < n_capabilities; i++) {
        nonmoving_flush_cap_upd_rem_set_blocks(capabilities[i]);
    }
}

/* Wait until a capability has flushed its update remembered set. Returns true
 * if all capabilities have flushed.
 */
bool nonmoving_wait_for_flush()
{
    ACQUIRE_LOCK(&upd_rem_set_lock);
    debugTrace(DEBUG_nonmoving_gc, "Flush count %d", upd_rem_set_flush_count);
    bool finished = (upd_rem_set_flush_count == n_capabilities) || (sched_state == SCHED_SHUTTING_DOWN);
    if (!finished) {
        waitCondition(&upd_rem_set_flushed_cond, &upd_rem_set_lock);
    }
    RELEASE_LOCK(&upd_rem_set_lock);
    return finished;
}

/* Signal to the mark thread that the RTS is shutting down. */
void nonmoving_shutting_down()
{
    ASSERT(sched_state == SCHED_SHUTTING_DOWN);
    signalCondition(&upd_rem_set_flushed_cond);
}

/* Notify capabilities that the synchronisation is finished; they may resume
 * execution.
 */
void nonmoving_finish_flush(Task *task)
{
    debugTrace(DEBUG_nonmoving_gc, "Finished update remembered set flush...");
    traceConcSyncEnd();
    releaseAllCapabilities(n_capabilities, NULL, task);
}
#else
void nonmoving_shutting_down() {}
#endif

/*********************************************************
 * Pushing to either the mark queue or remembered set
 *********************************************************/

STATIC_INLINE void
push (MarkQueue *q, const MarkQueueEnt *ent)
{
    // Are we at the end of the block?
    if (q->top->head == MARK_QUEUE_BLOCK_ENTRIES) {
        // Yes, this block is full.
        if (q->is_upd_rem_set) {
            nonmoving_add_upd_rem_set_blocks(q);
        } else {
            // allocate a fresh block.
            ACQUIRE_SM_LOCK;
            bdescr *bd = allocGroup(1);
            bd->link = q->blocks;
            q->blocks = bd;
            q->top = (MarkQueueBlock *) bd->start;
            q->top->head = 0;
            RELEASE_SM_LOCK;
        }
    }

    q->top->entries[q->top->head] = *ent;
    q->top->head++;
}

static
void push_closure (MarkQueue *q,
                   StgClosure *p,
                   StgClosure **origin)
{
    // TODO: Push this into callers where they already have the Bdescr
    if (HEAP_ALLOCED_GC(p) && (Bdescr((StgPtr) p)->gen != oldest_gen))
        return;

#if defined(DEBUG)
    ASSERT(LOOKS_LIKE_CLOSURE_PTR(p));
    if (RtsFlags.DebugFlags.sanity) {
        assert_in_nonmoving_heap((P_)p);
        if (origin)
            assert_in_nonmoving_heap((P_)origin);
    }
#endif

    MarkQueueEnt ent = {
        .type = MARK_CLOSURE,
        .mark_closure = {
            .p = UNTAG_CLOSURE(p),
            .origin = origin,
        }
    };
    push(q, &ent);
}

static
void push_array (MarkQueue *q,
                 const StgMutArrPtrs *array,
                 StgWord start_index)
{
    // TODO: Push this into callers where they already have the Bdescr
    if (HEAP_ALLOCED_GC(array) && (Bdescr((StgPtr) array)->gen != oldest_gen))
        return;

    MarkQueueEnt ent = {
        .type = MARK_ARRAY,
        .mark_array = {
            .array = array,
            .start_index = start_index
        }
    };
    push(q, &ent);
}

static
void push_thunk_srt (MarkQueue *q, const StgInfoTable *info)
{
    const StgThunkInfoTable *thunk_info = itbl_to_thunk_itbl(info);
    if (thunk_info->i.srt) {
        push_closure(q, (StgClosure*)GET_SRT(thunk_info), NULL);
    }
}

static
void push_fun_srt (MarkQueue *q, const StgInfoTable *info)
{
    const StgFunInfoTable *fun_info = itbl_to_fun_itbl(info);
    if (fun_info->i.srt) {
        push_closure(q, (StgClosure*)GET_FUN_SRT(fun_info), NULL);
    }
}

/*********************************************************
 * Pushing to the update remembered set
 *
 * upd_rem_set_push_* functions are directly called by
 * mutators and need to check whether the value is in
 * non-moving heap.
 *********************************************************/

// Check if the object is traced by the non-moving collector. This holds in two
// conditions:
//
// - Object is in non-moving heap
// - Object is a large (BF_LARGE) and marked as BF_NONMOVING
// - Object is static (HEAP_ALLOCED_GC(obj) == false)
//
static
bool check_in_nonmoving_heap(StgClosure *p) {
    if (HEAP_ALLOCED_GC(p)) {
        // This works for both large and small objects:
        return Bdescr((P_)p)->flags & BF_NONMOVING;
    } else {
        return true; // a static object
    }
}

/* Push the free variables of a (now-evaluated) thunk to the
 * update remembered set.
 */
void upd_rem_set_push_thunk(Capability *cap, StgThunk *origin)
{
    // TODO: Eliminate this conditional once it's folded into codegen
    if (!nonmoving_write_barrier_enabled) return;
    const StgThunkInfoTable *info = get_thunk_itbl((StgClosure*)origin);
    upd_rem_set_push_thunk_eager(cap, info, origin);
}

void upd_rem_set_push_thunk_eager(Capability *cap,
                                  const StgThunkInfoTable *info,
                                  StgThunk *thunk)
{
    switch (info->i.type) {
    case THUNK:
    case THUNK_1_0:
    case THUNK_0_1:
    case THUNK_2_0:
    case THUNK_1_1:
    case THUNK_0_2:
    {
        MarkQueue *queue = &cap->upd_rem_set.queue;
        push_thunk_srt(queue, &info->i);

        // Don't record the origin of objects living outside of the nonmoving
        // heap; we can't perform the selector optimisation on them anyways.
        bool record_origin = check_in_nonmoving_heap((StgClosure*)thunk);

        for (StgWord i = 0; i < info->i.layout.payload.ptrs; i++) {
            if (check_in_nonmoving_heap(thunk->payload[i])) {
                push_closure(queue,
                             thunk->payload[i],
                             record_origin ? &thunk->payload[i] : NULL);
            }
        }
        break;
    }
    case AP:
    {
        MarkQueue *queue = &cap->upd_rem_set.queue;
        StgAP *ap = (StgAP *) thunk;
        push_closure(queue, ap->fun, &ap->fun);
        mark_PAP_payload(queue, ap->fun, ap->payload, ap->n_args);
        break;
    }
    case THUNK_SELECTOR:
    case BLACKHOLE:
        // TODO: This is right, right?
        break;
    default:
        barf("upd_rem_set_push_thunk: invalid thunk pushed: p=%p, type=%d",
             thunk, info->i.type);
    }
}

void upd_rem_set_push_thunk_(StgRegTable *reg, StgThunk *origin)
{
    // TODO: Eliminate this conditional once it's folded into codegen
    if (!nonmoving_write_barrier_enabled) return;
    upd_rem_set_push_thunk(regTableToCapability(reg), origin);
}

void upd_rem_set_push_closure(Capability *cap,
                              StgClosure *p,
                              StgClosure **origin)
{
    if (!nonmoving_write_barrier_enabled) return;
    if (!check_in_nonmoving_heap(p)) return;
    MarkQueue *queue = &cap->upd_rem_set.queue;
    // We only shortcut things living in the nonmoving heap.
    if (! check_in_nonmoving_heap((StgClosure *) origin))
        origin = NULL;

    push_closure(queue, p, origin);
}

void upd_rem_set_push_closure_(StgRegTable *reg,
                               StgClosure *p,
                               StgClosure **origin)
{
    upd_rem_set_push_closure(regTableToCapability(reg), p, origin);
}

STATIC_INLINE bool needs_upd_rem_set_mark(StgClosure *p)
{
    // TODO: Deduplicate with mark_closure
    bdescr *bd = Bdescr((StgPtr) p);
    if (bd->gen != oldest_gen) {
        return false;
    } else if (bd->flags & BF_LARGE) {
        if (! (bd->flags & BF_NONMOVING_SWEEPING)) {
            return false;
        } else {
            return ! (bd->flags & BF_MARKED);
        }
    } else {
        struct nonmoving_segment *seg = nonmoving_get_segment((StgPtr) p);
        nonmoving_block_idx block_idx = nonmoving_get_block_idx((StgPtr) p);
        return nonmoving_get_mark(seg, block_idx) != nonmoving_mark_epoch;
    }
}

/* Set the mark bit; only to be called *after* we have fully marked the closure */
STATIC_INLINE void finish_upd_rem_set_mark(StgClosure *p)
{
    bdescr *bd = Bdescr((StgPtr) p);
    if (bd->flags & BF_LARGE) {
        // Someone else may have already marked it.
        ACQUIRE_LOCK(&nonmoving_large_objects_mutex);
        if (! (bd->flags & BF_MARKED)) {
            bd->flags |= BF_MARKED;
            dbl_link_remove(bd, &nonmoving_large_objects);
            dbl_link_onto(bd, &nonmoving_marked_large_objects);
            n_nonmoving_large_blocks -= bd->blocks;
            n_nonmoving_marked_large_blocks += bd->blocks;
        }
        RELEASE_LOCK(&nonmoving_large_objects_mutex);
    } else {
        struct nonmoving_segment *seg = nonmoving_get_segment((StgPtr) p);
        nonmoving_block_idx block_idx = nonmoving_get_block_idx((StgPtr) p);
        nonmoving_set_mark(seg, block_idx);
    }
}

void upd_rem_set_push_tso(Capability *cap, StgTSO *tso)
{
    // TODO: Eliminate this conditional once it's folded into codegen
    if (!nonmoving_write_barrier_enabled) return;
    if (!check_in_nonmoving_heap((StgClosure*)tso)) return;
    if (needs_upd_rem_set_mark((StgClosure *) tso)) {
        debugTrace(DEBUG_nonmoving_gc, "upd_rem_set: TSO %p\n", tso);
        mark_tso(&cap->upd_rem_set.queue, tso);
        finish_upd_rem_set_mark((StgClosure *) tso);
    }
}

void upd_rem_set_push_stack(Capability *cap, StgStack *stack)
{
    // TODO: Eliminate this conditional once it's folded into codegen
    if (!nonmoving_write_barrier_enabled) return;
    if (!check_in_nonmoving_heap((StgClosure*)stack)) return;
    if (needs_upd_rem_set_mark((StgClosure *) stack)) {
        // See Note [StgStack dirtiness flags and concurrent marking]
        while (1) {
            StgWord dirty = stack->dirty;
            StgWord res = cas(&stack->dirty, dirty, dirty | MUTATOR_MARKING_STACK);
            if (res & CONCURRENT_GC_MARKING_STACK) {
                // The concurrent GC has claimed the right to mark the stack. Wait until it finishes
                // marking before proceeding with mutation.
                while (needs_upd_rem_set_mark((StgClosure *) stack))
#if defined(PARALLEL_GC)
                    busy_wait_nop(); // TODO: Spinning here is unfortunate
#endif
                return;

            } else if (!(res & MUTATOR_MARKING_STACK)) {
                // We have claimed the right to mark the stack.
                break;
            }
        }

        debugTrace(DEBUG_nonmoving_gc, "upd_rem_set: STACK %p\n", stack->sp);
        mark_stack(&cap->upd_rem_set.queue, stack);
        finish_upd_rem_set_mark((StgClosure *) stack);}
}

int count_global_upd_rem_set_blocks()
{
    return countBlocks(upd_rem_set_block_list);
}
/*********************************************************
 * Pushing to the mark queue
 *********************************************************/

void mark_queue_push (MarkQueue *q, const MarkQueueEnt *ent)
{
    push(q, ent);
}

void mark_queue_push_closure (MarkQueue *q,
                              StgClosure *p,
                              StgClosure **origin)
{
    push_closure(q, p, origin);
}

/* TODO: Do we really never want to specify the origin here? */
void mark_queue_add_root(MarkQueue* q, StgClosure** root)
{
    mark_queue_push_closure(q, *root, NULL);
}

/* Push a closure to the mark queue without origin information */
void mark_queue_push_closure_ (MarkQueue *q, StgClosure *p)
{
    mark_queue_push_closure(q, p, NULL);
}

void mark_queue_push_fun_srt (MarkQueue *q, const StgInfoTable *info)
{
    push_fun_srt(q, info);
}

void mark_queue_push_thunk_srt (MarkQueue *q, const StgInfoTable *info)
{
    push_thunk_srt(q, info);
}

void mark_queue_push_array (MarkQueue *q,
                            const StgMutArrPtrs *array,
                            StgWord start_index)
{
    push_array(q, array, start_index);
}

/*********************************************************
 * Popping from the mark queue
 *********************************************************/

// Returns invalid MarkQueueEnt if queue is empty.
static MarkQueueEnt mark_queue_pop(MarkQueue *q)
{
    MarkQueueBlock *top;

again:
    top = q->top;

    // Are we at the beginning of the block?
    if (top->head == 0) {
        // Is this the first block of the queue?
        if (q->blocks->link == NULL) {
            // Yes, therefore queue is empty...
            MarkQueueEnt none = { .type = NULL_ENTRY };
            return none;
        } else {
            // No, unwind to the previous block and try popping again...
            bdescr *old_block = q->blocks;
            q->blocks = old_block->link;
            q->top = (MarkQueueBlock*)q->blocks->start;
            ACQUIRE_SM_LOCK;
            freeGroup(old_block); // TODO: hold on to a block to avoid repeated allocation/deallocation?
            RELEASE_SM_LOCK;
            goto again;
        }
    }

    q->top->head--;
    MarkQueueEnt ent = q->top->entries[q->top->head];

#if MARK_PREFETCH_QUEUE_DEPTH > 0
    // TODO
    int old_head = queue->prefetch_head;
    queue->prefetch_head = (queue->prefetch_head + 1) % MARK_PREFETCH_QUEUE_DEPTH;
    queue->prefetch_queue[old_head] = ent;
#endif

    return ent;
}

/*********************************************************
 * Creating and destroying MarkQueues and UpdRemSets
 *********************************************************/

/* Must hold sm_mutex. */
void init_mark_queue(MarkQueue *queue)
{
    bdescr *bd = allocGroup(1);
    queue->blocks = bd;
    queue->top = (MarkQueueBlock *) bd->start;
    queue->top->head = 0;
    queue->is_upd_rem_set = false;
    queue->marked_objects = allocHashTable();

#if MARK_PREFETCH_QUEUE_DEPTH > 0
    queue->prefetch_head = 0;
    memset(queue->prefetch_queue, 0,
           MARK_PREFETCH_QUEUE_DEPTH * sizeof(MarkQueueEnt));
#endif
}

/* Must hold sm_mutex. */
void init_upd_rem_set(UpdRemSet *rset)
{
    init_mark_queue(&rset->queue);
    rset->queue.is_upd_rem_set = true;
}

void free_mark_queue(MarkQueue *queue)
{
    bdescr* b = queue->blocks;
    ACQUIRE_SM_LOCK;
    while (b)
    {
        bdescr* b_ = b->link;
        freeGroup(b);
        b = b_;
    }
    RELEASE_SM_LOCK;
    freeHashTable(queue->marked_objects, NULL);
}

/*********************************************************
 * Marking
 *********************************************************/

static void mark_tso (MarkQueue *queue, StgTSO *tso)
{
    // TODO: Clear dirty if contains only old gen objects

    if (tso->bound != NULL) {
        mark_queue_push_closure_(queue, (StgClosure *) tso->bound->tso);
    }

    mark_queue_push_closure_(queue, (StgClosure *) tso->blocked_exceptions);
    mark_queue_push_closure_(queue, (StgClosure *) tso->bq);
    mark_queue_push_closure_(queue, (StgClosure *) tso->trec);
    mark_queue_push_closure_(queue, (StgClosure *) tso->stackobj);
    mark_queue_push_closure_(queue, (StgClosure *) tso->_link);
    if (   tso->why_blocked == BlockedOnMVar
        || tso->why_blocked == BlockedOnMVarRead
        || tso->why_blocked == BlockedOnBlackHole
        || tso->why_blocked == BlockedOnMsgThrowTo
        || tso->why_blocked == NotBlocked
        ) {
        mark_queue_push_closure_(queue, tso->block_info.closure);
    }
}

static void
do_push_closure(StgClosure **p, void *user)
{
    MarkQueue *queue = (MarkQueue *) user;
    // TODO: Origin? need reference to containing closure
    mark_queue_push_closure_(queue, *p);
}

static void
mark_large_bitmap (MarkQueue *queue,
                   StgClosure **p,
                   StgLargeBitmap *large_bitmap,
                   StgWord size)
{
    walk_large_bitmap(do_push_closure, p, large_bitmap, size, queue);
}

static void
mark_small_bitmap (MarkQueue *queue, StgClosure **p, StgWord size, StgWord bitmap)
{
    while (size > 0) {
        if ((bitmap & 1) == 0) {
            // TODO: Origin?
            mark_queue_push_closure(queue, *p, NULL);
        }
        p++;
        bitmap = bitmap >> 1;
        size--;
    }
}

static GNUC_ATTR_HOT
void mark_PAP_payload (MarkQueue *queue,
                       StgClosure *fun,
                       StgClosure **payload,
                       StgWord size)
{
    const StgFunInfoTable *fun_info = get_fun_itbl(UNTAG_CONST_CLOSURE(fun));
    ASSERT(fun_info->i.type != PAP);
    StgPtr p = (StgPtr) payload;

    StgWord bitmap;
    switch (fun_info->f.fun_type) {
    case ARG_GEN:
        bitmap = BITMAP_BITS(fun_info->f.b.bitmap);
        goto small_bitmap;
    case ARG_GEN_BIG:
        mark_large_bitmap(queue, payload, GET_FUN_LARGE_BITMAP(fun_info), size);
        break;
    case ARG_BCO:
        mark_large_bitmap(queue, payload, BCO_BITMAP(fun), size);
        break;
    default:
        bitmap = BITMAP_BITS(stg_arg_bitmaps[fun_info->f.fun_type]);
    small_bitmap:
        mark_small_bitmap(queue, (StgClosure **) p, size, bitmap);
        break;
    }
}

/* Helper for mark_stack; returns next stack frame. */
static StgPtr
mark_arg_block (MarkQueue *queue, const StgFunInfoTable *fun_info, StgClosure **args)
{
    StgWord bitmap, size;

    StgPtr p = (StgPtr)args;
    switch (fun_info->f.fun_type) {
    case ARG_GEN:
        bitmap = BITMAP_BITS(fun_info->f.b.bitmap);
        size = BITMAP_SIZE(fun_info->f.b.bitmap);
        goto small_bitmap;
    case ARG_GEN_BIG:
        size = GET_FUN_LARGE_BITMAP(fun_info)->size;
        mark_large_bitmap(queue, (StgClosure**)p, GET_FUN_LARGE_BITMAP(fun_info), size);
        p += size;
        break;
    default:
        bitmap = BITMAP_BITS(stg_arg_bitmaps[fun_info->f.fun_type]);
        size = BITMAP_SIZE(stg_arg_bitmaps[fun_info->f.fun_type]);
    small_bitmap:
        mark_small_bitmap(queue, (StgClosure**)p, size, bitmap);
        p += size;
        break;
    }
    return p;
}

static GNUC_ATTR_HOT void
mark_stack_ (MarkQueue *queue, StgPtr sp, StgPtr spBottom)
{
    ASSERT(sp <= spBottom);

    while (sp < spBottom) {
        const StgRetInfoTable *info = get_ret_itbl((StgClosure *)sp);
        switch (info->i.type) {
        case UPDATE_FRAME:
        {
            // See Note [upd-black-hole] in rts/Scav.c
            StgUpdateFrame *frame = (StgUpdateFrame *) sp;
            mark_queue_push_closure_(queue, frame->updatee);
            sp += sizeofW(StgUpdateFrame);
            continue;
        }

            // small bitmap (< 32 entries, or 64 on a 64-bit machine)
        case CATCH_STM_FRAME:
        case CATCH_RETRY_FRAME:
        case ATOMICALLY_FRAME:
        case UNDERFLOW_FRAME:
        case STOP_FRAME:
        case CATCH_FRAME:
        case RET_SMALL:
        {
            StgWord bitmap = BITMAP_BITS(info->i.layout.bitmap);
            StgWord size   = BITMAP_SIZE(info->i.layout.bitmap);
            // NOTE: the payload starts immediately after the info-ptr, we
            // don't have an StgHeader in the same sense as a heap closure.
            sp++;
            mark_small_bitmap(queue, (StgClosure **) sp, size, bitmap);
            sp += size;
        }
        follow_srt:
            if (info->i.srt) {
                mark_queue_push_closure_(queue, (StgClosure*)GET_SRT(info));
            }
            continue;

        case RET_BCO: {
            sp++;
            mark_queue_push_closure_(queue, *(StgClosure**)sp);
            StgBCO *bco = (StgBCO *)*sp;
            sp++;
            StgWord size = BCO_BITMAP_SIZE(bco);
            mark_large_bitmap(queue, (StgClosure **) sp, BCO_BITMAP(bco), size);
            sp += size;
            continue;
        }

          // large bitmap (> 32 entries, or > 64 on a 64-bit machine)
        case RET_BIG:
        {
            StgWord size;

            size = GET_LARGE_BITMAP(&info->i)->size;
            sp++;
            mark_large_bitmap(queue, (StgClosure **) sp, GET_LARGE_BITMAP(&info->i), size);
            sp += size;
            // and don't forget to follow the SRT
            goto follow_srt;
        }

        case RET_FUN:
        {
            StgRetFun *ret_fun = (StgRetFun *)sp;
            const StgFunInfoTable *fun_info;

            mark_queue_push_closure_(queue, ret_fun->fun);
            fun_info = get_fun_itbl(UNTAG_CLOSURE(ret_fun->fun));
            sp = mark_arg_block(queue, fun_info, ret_fun->payload);
            goto follow_srt;
        }

        default:
            barf("mark_stack: weird activation record found on stack: %d", (int)(info->i.type));
        }
    }
}

static GNUC_ATTR_HOT void
mark_stack (MarkQueue *queue, StgStack *stack)
{
    // TODO: Clear dirty if contains only old gen objects

    mark_stack_(queue, stack->sp, stack->stack + stack->stack_size);
}

static GNUC_ATTR_HOT void
mark_closure (MarkQueue *queue, StgClosure *p, StgClosure **origin)
{
 try_again:
    p = UNTAG_CLOSURE(p);

#   define PUSH_FIELD(obj, field)                                \
        mark_queue_push_closure(queue,                           \
                                (StgClosure *) (obj)->field,     \
                                (StgClosure **) &(obj)->field)

    if (!HEAP_ALLOCED_GC(p)) {
        const StgInfoTable *info = get_itbl(p);
        StgHalfWord type = info->type;

        if (type == CONSTR_0_1 || type == CONSTR_0_2 || type == CONSTR_NOCAF) {
            // no need to put these on the static linked list, they don't need
            // to be marked.
            return;
        }

        if (lookupHashTable(queue->marked_objects, (W_)p)) {
            // already marked
            return;
        }

        insertHashTable(queue->marked_objects, (W_)p, (P_)1);

        switch (type) {

        case THUNK_STATIC:
            if (info->srt != 0) {
                mark_queue_push_thunk_srt(queue, info); // TODO this function repeats the check above
            }
            return;

        case FUN_STATIC:
            if (info->srt != 0 || info->layout.payload.ptrs != 0) {
                mark_queue_push_fun_srt(queue, info); // TODO this function repeats the check above

                // a FUN_STATIC can also be an SRT, so it may have pointer
                // fields.  See Note [SRTs] in CmmBuildInfoTables, specifically
                // the [FUN] optimisation.
                // TODO (osa) I don't understand this comment
                for (StgHalfWord i = 0; i < info->layout.payload.ptrs; ++i) {
                    PUSH_FIELD(p, payload[i]);
                }
            }
            return;

        case IND_STATIC:
            PUSH_FIELD((StgInd *) p, indirectee);
            return;

        case CONSTR:
        case CONSTR_1_0:
        case CONSTR_2_0:
        case CONSTR_1_1:
            for (StgHalfWord i = 0; i < info->layout.payload.ptrs; ++i) {
                PUSH_FIELD(p, payload[i]);
            }
            return;

        default:
            barf("mark_closure(static): strange closure type %d", (int)(info->type));
        }
    }

    bdescr *bd = Bdescr((StgPtr) p);

    if (bd->gen != oldest_gen) {
        // Here we have an object living outside of the non-moving heap. Since
        // we moved everything to the non-moving heap before starting the major
        // collection, we know that we don't need to trace it: it was allocated
        // after we took our snapshot.
#if !defined(CONCURRENT_MARK)
        // This should never happen in the non-concurrent case
        barf("Closure outside of non-moving heap: %p", p);
#else
        return;
#endif
    }

    ASSERTM(LOOKS_LIKE_CLOSURE_PTR(p), "invalid closure, info=%p", p->header.info);
#if !defined(CONCURRENT_MARK)
    // A moving collection running concurrently with the mark may
    // evacuate a reference living in the nonmoving heap, resulting in a
    // forwarding pointer.
    ASSERT(!IS_FORWARDING_PTR(p->header.info));
#endif

    if (bd->flags & BF_NONMOVING) {

        if (bd->flags & BF_LARGE) {
            if (! (bd->flags & BF_NONMOVING_SWEEPING)) {
                // Not in the snapshot
                return;
            }
            if (bd->flags & BF_MARKED) {
                return;
            }

            // Mark contents
            p = (StgClosure*)bd->start;
        } else {
            struct nonmoving_segment *seg = nonmoving_get_segment((StgPtr) p);
            nonmoving_block_idx block_idx = nonmoving_get_block_idx((StgPtr) p);

            /* We don't mark blocks that,
             *  - were not live at the time that the snapshot was taken, or
             *  - we have already marked this cycle
             */
            uint8_t mark = nonmoving_get_mark(seg, block_idx);
            /* Don't mark things we've already marked (since we may loop) */
            if (mark == nonmoving_mark_epoch)
                return;

            StgClosure *snapshot_loc =
              (StgClosure *) nonmoving_segment_get_block(seg, seg->next_free_snap);
            if (p >= snapshot_loc && mark == 0) {
                /* In this case we are in segment which wasn't filled at the
                 * time that the snapshot was taken. We mustn't trace things
                 * above the allocation pointer that aren't marked since they
                 * may not be valid objects.
                 */
                return;
            }
        }
    }

    // A pinned object that is still attached to a capability (because it's not
    // filled yet). No need to trace it pinned objects can't contain poiners.
    else if (bd->flags & BF_PINNED) {
#if defined(DEBUG)
        bool found_it = false;
        for (uint32_t i = 0; i < n_capabilities; ++i) {
            if (capabilities[i]->pinned_object_block == bd) {
                found_it = true;
                break;
            }
        }
        ASSERT(found_it);
#endif
        return;
    }

    else {
        barf("Strange closure in nonmoving mark: %p", p);
    }

    /////////////////////////////////////////////////////
    // Trace pointers
    /////////////////////////////////////////////////////

    const StgInfoTable *info = get_itbl(p);
    switch (info->type) {

    case MVAR_CLEAN:
    case MVAR_DIRTY: {
        StgMVar *mvar = (StgMVar *) p;
        PUSH_FIELD(mvar, head);
        PUSH_FIELD(mvar, tail);
        PUSH_FIELD(mvar, value);
        break;
    }

    case TVAR: {
        StgTVar *tvar = ((StgTVar *)p);
        PUSH_FIELD(tvar, current_value);
        PUSH_FIELD(tvar, first_watch_queue_entry);
        break;
    }

    case FUN_2_0:
        mark_queue_push_fun_srt(queue, info);
        PUSH_FIELD(p, payload[1]);
        PUSH_FIELD(p, payload[0]);
        break;

    case THUNK_2_0: {
        StgThunk *thunk = (StgThunk *) p;
        mark_queue_push_thunk_srt(queue, info);
        PUSH_FIELD(thunk, payload[1]);
        PUSH_FIELD(thunk, payload[0]);
        break;
    }

    case CONSTR_2_0:
        PUSH_FIELD(p, payload[1]);
        PUSH_FIELD(p, payload[0]);
        break;

    case THUNK_1_0:
        mark_queue_push_thunk_srt(queue, info);
        PUSH_FIELD((StgThunk *) p, payload[0]);
        break;

    case FUN_1_0:
        mark_queue_push_fun_srt(queue, info);
        PUSH_FIELD(p, payload[0]);
        break;

    case CONSTR_1_0:
        PUSH_FIELD(p, payload[0]);
        break;

    case THUNK_0_1:
        mark_queue_push_thunk_srt(queue, info);
        break;

    case FUN_0_1:
        mark_queue_push_fun_srt(queue, info);
        break;

    case CONSTR_0_1:
    case CONSTR_0_2:
        break;

    case THUNK_0_2:
        mark_queue_push_thunk_srt(queue, info);
        break;

    case FUN_0_2:
        mark_queue_push_fun_srt(queue, info);
        break;

    case THUNK_1_1:
        mark_queue_push_thunk_srt(queue, info);
        PUSH_FIELD((StgThunk *) p, payload[0]);
        break;

    case FUN_1_1:
        mark_queue_push_fun_srt(queue, info);
        PUSH_FIELD(p, payload[0]);
        break;

    case CONSTR_1_1:
        PUSH_FIELD(p, payload[0]);
        break;

    case FUN:
        mark_queue_push_fun_srt(queue, info);
        goto gen_obj;

    case THUNK: {
        mark_queue_push_thunk_srt(queue, info);
        for (StgWord i = 0; i < info->layout.payload.ptrs; i++) {
            StgClosure **field = &((StgThunk *) p)->payload[i];
            mark_queue_push_closure(queue, *field, field);
        }
        break;
    }

    gen_obj:
    case CONSTR:
    case CONSTR_NOCAF:
    case WEAK:
    case PRIM:
    {
        for (StgWord i = 0; i < info->layout.payload.ptrs; i++) {
            StgClosure **field = &((StgClosure *) p)->payload[i];
            mark_queue_push_closure(queue, *field, field);
        }
        break;
    }

    case BCO: {
        StgBCO *bco = (StgBCO *)p;
        PUSH_FIELD(bco, instrs);
        PUSH_FIELD(bco, literals);
        PUSH_FIELD(bco, ptrs);
        break;
    }


    case IND:
    case BLACKHOLE:
        PUSH_FIELD((StgInd *) p, indirectee);
        break;

    case MUT_VAR_CLEAN:
    case MUT_VAR_DIRTY:
        PUSH_FIELD((StgMutVar *)p, var);
        break;

    case BLOCKING_QUEUE: {
        StgBlockingQueue *bq = (StgBlockingQueue *)p;
        PUSH_FIELD(bq, bh);
        PUSH_FIELD(bq, owner);
        PUSH_FIELD(bq, queue);
        PUSH_FIELD(bq, link);
        break;
    }

    case THUNK_SELECTOR:
        PUSH_FIELD((StgSelector *) p, selectee);
        // TODO: selector optimization
        break;

    case AP_STACK: {
        StgAP_STACK *ap = (StgAP_STACK *)p;
        PUSH_FIELD(ap, fun);
        mark_stack_(queue, (StgPtr) ap->payload, (StgPtr) ap->payload + ap->size);
        break;
    }

    case PAP: {
        StgPAP *pap = (StgPAP *) p;
        PUSH_FIELD(pap, fun);
        mark_PAP_payload(queue, pap->fun, pap->payload, pap->n_args);
        break;
    }

    case AP: {
        StgAP *ap = (StgAP *) p;
        PUSH_FIELD(ap, fun);
        mark_PAP_payload(queue, ap->fun, ap->payload, ap->n_args);
        break;
    }

    case ARR_WORDS:
        // nothing to follow
        break;

    case MUT_ARR_PTRS_CLEAN:
    case MUT_ARR_PTRS_DIRTY:
    case MUT_ARR_PTRS_FROZEN_CLEAN:
    case MUT_ARR_PTRS_FROZEN_DIRTY:
        // TODO: Check this against Scav.c
        mark_queue_push_array(queue, (StgMutArrPtrs *) p, 0);
        break;

    case SMALL_MUT_ARR_PTRS_CLEAN:
    case SMALL_MUT_ARR_PTRS_DIRTY:
    case SMALL_MUT_ARR_PTRS_FROZEN_CLEAN:
    case SMALL_MUT_ARR_PTRS_FROZEN_DIRTY: {
        StgSmallMutArrPtrs *arr = (StgSmallMutArrPtrs *) p;
        for (StgWord i = 0; i < arr->ptrs; i++) {
            StgClosure **field = &arr->payload[i];
            mark_queue_push_closure(queue, *field, field);
        }
        break;
    }

    case TSO:
        mark_tso(queue, (StgTSO *) p);
        break;

    case STACK: {
      StgStack *stack = (StgStack *) p;
      // See Note [StgStack dirtiness flags and concurrent marking]
      StgWord dirty = stack->dirty;
      while (1) {
          if (dirty & MUTATOR_MARKING_STACK) {
              // A mutator has already started marking the stack; we just let it
              // do its thing and move on. There's no reason to wait; we know that
              // the stack will be fully marked before we sweep due to the final
              // post-mark synchronization.
              return;
          } else if (dirty & CONCURRENT_GC_MARKING_STACK) {
              mark_stack(queue, stack);
              break;
          } else {
              StgWord old_dirty = cas(&stack->dirty, dirty, dirty | CONCURRENT_GC_MARKING_STACK);
              dirty = stack->dirty;
          }
      }
      break;
    }

    case MUT_PRIM: {
        for (StgHalfWord p_idx = 0; p_idx < info->layout.payload.ptrs; ++p_idx) {
            StgClosure **field = &p->payload[p_idx];
            mark_queue_push_closure(queue, *field, field);
        }
        break;
    }

    case TREC_CHUNK: {
        StgTRecChunk *tc = ((StgTRecChunk *) p);
        PUSH_FIELD(tc, prev_chunk);
        TRecEntry *end = &tc->entries[tc->next_entry_idx];
        for (TRecEntry *e = &tc->entries[0]; e < end; e++) {
            mark_queue_push_closure_(queue, (StgClosure *) e->tvar);
            mark_queue_push_closure_(queue, (StgClosure *) e->expected_value);
            mark_queue_push_closure_(queue, (StgClosure *) e->new_value);
        }
        break;
    }

    case WHITEHOLE:
        while (get_itbl(p)->type == WHITEHOLE);
            // busy_wait_nop(); // FIXME
        goto try_again;

    default:
        barf("mark_closure: unimplemented/strange closure type %d @ %p",
             info->type, p);
    }

#   undef PUSH_FIELD

    /* Set the mark bit: it's important that we do this only after we actually push
     * the object's pointers since in the case of marking stacks there may be a
     * mutator waiting for us to finish so it can start execution.
     */
    if (bd->flags & BF_LARGE) {
        /* Marking a large object isn't idempotent since we move it to
         * nonmoving_marked_large_objects; to ensure that we don't repeatedly
         * mark a large object, we only set BF_MARKED on large objects in the
         * nonmoving heap while holding nonmoving_large_objects_mutex
         */
        ACQUIRE_LOCK(&nonmoving_large_objects_mutex);
        if (! (bd->flags & BF_MARKED)) {
            // Remove the object from nonmoving_large_objects and link it to
            // nonmoving_marked_large_objects
            dbl_link_remove(bd, &nonmoving_large_objects);
            dbl_link_onto(bd, &nonmoving_marked_large_objects);
            n_nonmoving_large_blocks -= bd->blocks;
            n_nonmoving_marked_large_blocks += bd->blocks;
            bd->flags |= BF_MARKED;
        }
        RELEASE_LOCK(&nonmoving_large_objects_mutex);
    } else {
        // TODO: Kill repetition
        struct nonmoving_segment *seg = nonmoving_get_segment((StgPtr) p);
        nonmoving_block_idx block_idx = nonmoving_get_block_idx((StgPtr) p);
        nonmoving_set_mark(seg, block_idx);
    }
}

/* This is the main mark loop.
 * Invariants:
 *
 *  a. nonmoving_prepare_mark has been called.
 *  b. the nursery has been fully evacuated into the non-moving generation.
 *  c. the mark queue has been seeded with a set of roots.
 *
 */
GNUC_ATTR_HOT void nonmoving_mark(MarkQueue *queue)
{
    traceConcMarkBegin();
    while (true) {
        MarkQueueEnt ent = mark_queue_pop(queue);

        switch (ent.type) {
        case MARK_CLOSURE:
            mark_closure(queue, ent.mark_closure.p, ent.mark_closure.origin);
            break;
        case MARK_ARRAY: {
            const StgMutArrPtrs *arr = ent.mark_array.array;
            StgWord start = ent.mark_array.start_index;
            StgWord end = start + MARK_ARRAY_CHUNK_LENGTH;
            if (end < arr->ptrs) {
                mark_queue_push_array(queue, ent.mark_array.array, end);
            } else {
                end = arr->ptrs;
            }
            for (StgWord i = start; i < end; i++) {
                mark_queue_push_closure_(queue, arr->payload[i]);
            }
            break;
        }
        case NULL_ENTRY:
            // Perhaps the update remembered set has more to mark...
            if (upd_rem_set_block_list) {
                ACQUIRE_LOCK(&upd_rem_set_lock);
                bdescr *old = queue->blocks;
                queue->blocks = upd_rem_set_block_list;
                queue->top = (MarkQueueBlock *) queue->blocks->start;
                upd_rem_set_block_list = NULL;
                RELEASE_LOCK(&upd_rem_set_lock);

                ACQUIRE_SM_LOCK;
                freeGroup(old);
                RELEASE_SM_LOCK;
            } else {
                // Nothing more to do
                traceConcMarkEnd();
                return;
            }
        }
    }
}

// A variant of `isAlive` that works for non-moving heap. Used for:
//
// - Collecting weak pointers; checking key of a weak pointer.
// - Resurrecting threads; checking if a thread is dead.
// - Sweeping object lists: large_objects, mut_list, stable_name_table.
//
bool nonmoving_is_alive(StgClosure *p)
{
    // Ignore static closures. See comments in `isAlive`.
    if (!HEAP_ALLOCED_GC(p)) {
        return true;
    }

    bdescr *bd = Bdescr((P_)p);

    // All non-static objects in the non-moving heap should be marked as
    // BF_NONMOVING
    ASSERT(bd->flags & BF_NONMOVING);

    if (bd->flags & BF_LARGE) {
        return (bd->flags & BF_NONMOVING_SWEEPING) == 0
                   // the large object wasn't in the snapshot and therefore wasn't marked
            || (bd->flags & BF_MARKED) != 0;
                   // The object was marked
    } else {
        struct nonmoving_segment *seg = nonmoving_get_segment((StgPtr) p);
        nonmoving_block_idx i = nonmoving_get_block_idx((StgPtr) p);
        if (i >= seg->next_free_snap) {
            // If the object is allocated after next_free_snap then it must have
            // been allocated after we took the snapshot and consequently we
            // have no guarantee that it is marked, even if it is still reachable.
            // This is because the snapshot invariant only guarantees that things in
            // the nonmoving heap at the time that the snapshot is taken are marked.
            return true;
        } else {
            return nonmoving_closure_marked((P_)p);
        }
    }
}

// Non-moving heap variant of `tidyWeakList`
bool nonmoving_mark_weaks(struct MarkQueue_ *queue)
{
    bool did_work = false;

    StgWeak **last_w = &oldest_gen->old_weak_ptr_list;
    StgWeak *next_w;
    for (StgWeak *w = oldest_gen->old_weak_ptr_list; w != NULL; w = next_w) {
        if (w->header.info == &stg_DEAD_WEAK_info) {
            // finalizeWeak# was called on the weak
            next_w = w->link;
            *last_w = next_w;
            continue;
        }

        // Otherwise it's a live weak
        ASSERT(w->header.info == &stg_WEAK_info);

        if (nonmoving_is_alive(w->key)) {
            nonmoving_mark_live_weak(queue, w);
            did_work = true;

            // remove this weak ptr from old_weak_ptr list
            *last_w = w->link;
            next_w = w->link;

            // and put it on the weak ptr list
            w->link = oldest_gen->weak_ptr_list;
            oldest_gen->weak_ptr_list = w;
        } else {
            last_w = &(w->link);
            next_w = w->link;
        }
    }

    return did_work;
}

void nonmoving_mark_dead_weak(struct MarkQueue_ *queue, StgWeak *w)
{
    if (w->cfinalizers != &stg_NO_FINALIZER_closure) {
        mark_queue_push_closure_(queue, w->value);
    }
    mark_queue_push_closure_(queue, w->finalizer);
}

void nonmoving_mark_live_weak(struct MarkQueue_ *queue, StgWeak *w)
{
    ASSERT(nonmoving_closure_marked((P_)w));
    mark_queue_push_closure_(queue, w->value);
    mark_queue_push_closure_(queue, w->finalizer);
    mark_queue_push_closure_(queue, w->cfinalizers);
}

void nonmoving_mark_dead_weaks(struct MarkQueue_ *queue)
{
    StgWeak *next_w;
    for (StgWeak *w = oldest_gen->old_weak_ptr_list; w; w = next_w) {
        ASSERT(!nonmoving_closure_marked((P_)(w->key)));
        nonmoving_mark_dead_weak(queue, w);
        next_w = w ->link;
        w->link = dead_weak_ptr_list;
        dead_weak_ptr_list = w;
    }
}

void nonmoving_tidy_threads()
{
    StgTSO *next;
    StgTSO **prev = &oldest_gen->old_threads;
    for (StgTSO *t = oldest_gen->old_threads; t != END_TSO_QUEUE; t = next) {

        next = t->global_link;

        if (nonmoving_is_alive((StgClosure*)t)) {
            // alive
            *prev = next;

            // move this thread onto threads list
            t->global_link = oldest_gen->threads;
            oldest_gen->threads = t;
        } else {
            // not alive (yet): leave this thread on the old_threads list
            prev = &(t->global_link);
        }
    }
}

void nonmoving_resurrect_threads(struct MarkQueue_ *queue)
{
    StgTSO *next;
    for (StgTSO *t = oldest_gen->old_threads; t != END_TSO_QUEUE; t = next) {
        next = t->global_link;

        switch (t->what_next) {
        case ThreadKilled:
        case ThreadComplete:
            continue;
        default:
            mark_queue_push_closure_(queue, (StgClosure*)t);
            t->global_link = resurrected_threads;
            resurrected_threads = t;
        }
    }
}

#ifdef DEBUG

void print_queue_ent(MarkQueueEnt *ent)
{
    if (ent->type == MARK_CLOSURE) {
        debugBelch("Closure: ");
        printClosure(ent->mark_closure.p);
    } else if (ent->type == MARK_ARRAY) {
        debugBelch("Array\n");
    } else {
        debugBelch("End of mark\n");
    }
}

void print_mark_queue(MarkQueue *q)
{
    debugBelch("======== MARK QUEUE ========\n");
    for (bdescr *block = q->blocks; block; block = block->link) {
        MarkQueueBlock *queue = (MarkQueueBlock*)block->start;
        for (uint32_t i = 0; i < queue->head; ++i) {
            print_queue_ent(&queue->entries[i]);
        }
    }
    debugBelch("===== END OF MARK QUEUE ====\n");
}

#endif
