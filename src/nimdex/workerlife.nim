## Release Nimdex-owned Sigils schedulers after joining their OS threads.
## Sigils' join only joins; its base destructor does not release owned fields.

import std/[locks, sets, tables]
import sigils

proc proxiesReleased(thread: SigilThreadPtr): bool =
  for actor in thread.references.values:
    let endpoint = actor.endpoint()
    withLock endpoint[].lock:
      if endpoint[].handles != 0:
        return false
  true

proc clearJoinedState(thread: SigilThreadPtr) =
  thread.clearWakeCallbacks()
  for actor in thread.references.values:
    actor.closeEndpoint()
  reset(thread.references)
  reset(thread.signaled)
  reset(thread.toCancel)
  reset(thread.agent)
  when defined(sigilsDebug):
    reset(thread.debugName)
  deinitLock(thread.signaledLock)

proc disposeJoined*(thread: SigilThreadDefaultPtr): bool =
  ## The caller must join first and stop producing work. A completion callback
  ## may still own the last proxy: defer freeing until that callback unwinds.
  if thread.isNil:
    return true
  if not proxiesReleased(thread):
    return false
  clearJoinedState(thread)
  `=destroy`(thread[])
  deallocShared(thread)
  true

proc disposeJoined*(pool: SigilThreadPoolPtr): bool =
  ## All producer proxies must be released before disposing a joined pool.
  if pool.isNil:
    return true
  if not proxiesReleased(pool):
    return false
  clearJoinedState(pool)
  deinitCond(pool.queueCond)
  deinitLock(pool.queueLock)
  `=destroy`(pool[])
  deallocShared(pool)
  true
