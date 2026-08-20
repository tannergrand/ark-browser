import SwiftUI

/// Which side of a pane a dragged tab would land on.
///
/// All that survives of six abandoned drag-and-drop attempts. Sidebar and pane
/// drops now run through `TabDragCoordinator`, which tracks the pointer directly
/// — see the history note there before reaching for a drop API again.
enum DropZone: Equatable {
    case left
    case right
    case none
}
