# Shoji

Shoji manages macOS windows and workspaces. Its compatibility investigation vocabulary distinguishes evidence from confirmed behavior.

## Language

**Dock target**:
A private Dock function, global reference, or instruction site that Shoji needs for an operation.
_Avoid_: Hook, when referring only to a location being investigated.

**Instruction pattern**:
A sequence of instruction bytes, with optional wildcards, used to locate a Dock target. It is distinct from a cryptographic code signature.
_Avoid_: Signature without specifying which kind.

**Pattern match**:
A location whose bytes satisfy an instruction pattern. A match alone does not establish target identity or working behavior.

**Comparison assistance**:
Evidence that helps a maintainer investigate differences between Dock versions and identify potential replacement patterns.

**Replacement candidate**:
A location proposed as the counterpart of a Dock target in a different build. Its ranking and supporting evidence do not establish verified identity or working behavior.

**Dock snapshot**:
A preserved Dock binary together with its image identity and the provenance of its OS version and build metadata.

**Scan profile**:
A version-specific set of known instruction patterns and search starts used to investigate a Dock image. Choosing a profile does not declare the image compatible with Shoji.

**Opening lifecycle**:
The sequence a new managed window follows as it becomes ready, joins its layout, and is presented to the user. The sequence is shared across applications and tiling layouts.

**Layout policy**:
The rules that determine window dimensions and placement within a workspace. Different layout policies share the same opening lifecycle.

**BSP layout**:
A tiling layout that recursively partitions a finite working area among windows. Adding a window can resize existing tiles to make room.

**Scrolling layout**:
A tiling layout with columns on a horizontal canvas viewed through a viewport. Adding a column can preserve existing column widths and extend the canvas.

**Opening preparation**:
The period in which a new managed window's placement and accepted size are established. Preparation itself leaves existing windows unchanged and usable; independent desktop actions can still change the layout.

**Opening transition**:
The single coordinated visible change in which a prepared newcomer grows into position while neighbouring windows move or resize according to the layout policy.

**Pending window**:
A new managed window awaiting usable initial geometry or valid layout placement before joining its layout. Delayed preparation or insufficient room does not change its intended tiling status.

**Independent window**:
A window that is a separate participant in the workspace layout, rather than auxiliary UI belonging to another window.

**Parent-associated dialog**:
An auxiliary window belonging to a parent window, such as a file picker or permission dialog. It stays above its parent without joining or reflowing the tiling layout.

**Layout admission**:
An independent window joining the workspace layout. Repeated observations of the same window and updates to auxiliary UI are not new admissions.

**Opening focus intent**:
The focus intention associated with opening a new independent window. A later deliberate focus selection supersedes it, so delayed completion cannot take focus back.

**Motion retargeting**:
Updating the layout motion toward a new destination while preserving continuity from the current visible positions. Retargeting does not constitute another opening of an existing window.

**Native size constraint**:
A limit that a window currently enforces on its dimensions. Constraints may depend on the window's content or state and can affect the geometry selected by the layout policy.

**Split ratio**:
The proportion of a BSP partition assigned to each of its two children. Native size constraints can adjust the requested proportion while preserving the chosen split direction.
