import SwiftUI
import SwiftData

/// A notebook's Move to Shelf row: every shelf by its path and spine, the one it is on checked.
struct MoveToShelfMenu: View {
    let current: UUID?
    let move: (FolderRecord?) -> Void
    @Query(sort: \FolderRecord.sortIndex) private var folders: [FolderRecord]

    var body: some View {
        let tree = FolderTree(folders: folders)
        OwlLunaMenu {
            Button { move(nil) } label: { Label("Not on a shelf", systemImage: "tray") }
                .menuChosen(current == nil)
            ForEach(folders) { folder in
                Button { move(folder) } label: {
                    Label { Text(tree.path(of: folder.id)) } icon: { SpineChip(cloth: folder.cloth, width: 12) }
                }
                .menuChosen(current == folder.id)
            }
        } label: { Label("Move to Shelf", systemImage: "folder") }
    }
}
