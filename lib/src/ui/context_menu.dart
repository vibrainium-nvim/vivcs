import 'package:nvim/nvim.dart';

/// A single entry in the VCS right-click [VcsContextMenu].
class VcsContextMenuItem extends NvimContextMenuItem {
  const VcsContextMenuItem({
    required super.label,
    required super.shortcut,
    required super.onSelect,
  });
}

/// Floating context menu for right-click actions in the VCS sidebar.
class VcsContextMenu extends NvimContextMenu<VcsContextMenuItem> {
  VcsContextMenu(Nvim nvim)
      : super(
          nvim: nvim,
          actionPrefix: 'vcs',
          filetype: 'vivcs-menu',
          augroupName: 'VivcsContextMenu',
          rightClickAction: 'vcs.context_menu',
        );

  Future<void> open({
    required List<VcsContextMenuItem> items,
    String title = 'VCS Actions',
    int? anchorWin,
    int row = 1,
    int col = 2,
    Future<void> Function()? onCancel,
  }) =>
      openMenu(
        items: items,
        title: title,
        anchorWin: anchorWin,
        row: row,
        col: col,
        onCancel: onCancel,
      );
}
