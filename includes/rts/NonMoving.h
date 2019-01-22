/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 2018-2019
 *
 * Non-moving garbage collector
 *
 * Do not #include this file directly: #include "Rts.h" instead.
 *
 * To understand the structure of the RTS headers, see the wiki:
 *   http://ghc.haskell.org/trac/ghc/wiki/Commentary/SourceTree/Includes
 *
 * -------------------------------------------------------------------------- */

#pragma once

/* This is called by the code generator */
extern DLL_IMPORT_RTS
void upd_rem_set_push_closure_(StgRegTable *reg,
                               StgClosure *p,
                               StgClosure **origin);


void upd_rem_set_push_closure(Capability *cap,
                              StgClosure *p,
                              StgClosure **origin);
