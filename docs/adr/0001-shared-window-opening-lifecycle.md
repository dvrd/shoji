# Share the opening lifecycle across applications and tiling layouts

All managed windows will follow one application-independent opening lifecycle,
using Niri's lifecycle behaviour as the reference. Layout policy remains separate:
BSP redistributes its finite working area, while scrolling can preserve column
widths and extend its horizontal canvas. This standardizes opening behaviour
while retaining the geometry appropriate to each layout.

Preparation itself leaves the existing visible layout unchanged and usable. Once the
new window's placement and accepted size are ready, a single coordinated opening
transition grows the newcomer into position while its neighbours move or resize.
Applications may take different amounts of time to prepare; they share the same
visible sequence.

Readiness delays and synchronization deadlines never convert a managed window
to floating. A newcomer without usable initial geometry stays pending while the
existing layout remains usable. Once admitted, it retains its tiling status;
releasing a synchronization wait lets ready participants proceed, and late
updates reconcile without replaying the opening transition. The automatic
floating fallback was explicitly rejected in favour of predictable behaviour.

Parent-associated dialogs remain above their parent and do not join or reflow
the tiling layout. Classification is application-independent: auxiliary UI
appearing or updating is not admission of a new independent window. This keeps
dialog interactions from unexpectedly rearranging the user's workspace.

A deliberate focus change made while a newcomer is preparing takes precedence
over that opening's completion. Finishing preparation must not steal focus back;
this precedence is the same across applications.

Closing an existing tiled window is processed immediately, even while another
window is preparing. Pending openings recalculate against the remaining layout;
they must not restore stale geometry or reserve space for the closed window.
Preparation does not block normal desktop actions.

Pending windows are admitted in readiness order rather than creation order. A
ready newcomer can open while an earlier newcomer is still preparing; a slow
application must not block another application's admission. Each newcomer still
passes through the same opening lifecycle.

A window that becomes ready during an existing opening transition is admitted
immediately. Layout motion retargets from current visible positions toward the
updated layout, without jumping back or replaying another window's opening
effect. Animation completion is not an admission prerequisite.

In BSP, native minimum sizes can adjust the proposed split ratio when all
participants can still fit. Preserve the selected split direction and deviate
from the requested ratio only as much as necessary. Establish the valid geometry
during preparation, before starting the visible opening transition.

For the first iteration, when native constraints still prevent a valid BSP
placement, keep the newcomer pending with a clear "needs more room" indication.
Existing windows remain usable. When room becomes available, the pending window
can complete the ordinary opening lifecycle. Do not overlap windows or silently
change the selected layout to admit it. Revisit this policy after observing its
usability in practice.
