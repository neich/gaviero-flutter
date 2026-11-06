/// The connected app: a section bar that never goes away (Files, Shells,
/// Conversations) over one navigator per section. A section is built the
/// first time it is opened and then stays mounted, so switching back lands
/// on the same folder tree, open file, shell tab and draft, or conversation
/// scroll position. The screen is keyed by instance in `main.dart`: another
/// workspace starts from fresh sections.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/controller.dart';
import '../util/links.dart';
import 'chat_screen.dart';
import 'explorer_screen.dart';
import 'link_actions.dart';
import 'shell_screen.dart';

enum HomeSection {
  files('Files', Icons.folder_open),
  shells('Shells', Icons.terminal),
  conversations('Conversations', Icons.chat_bubble_outline);

  final String label;
  final IconData icon;

  const HomeSection(this.label, this.icon);
}

class HomeScreen extends StatefulWidget {
  final RemoteController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HomeSection _section = HomeSection.conversations;
  final _opened = <HomeSection>{HomeSection.conversations};
  final _navigators = {
    for (final section in HomeSection.values)
      section: GlobalKey<NavigatorState>(debugLabel: 'section ${section.name}'),
  };

  RemoteController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.conversationFocus.addListener(_focusConversation);
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.conversationFocus.removeListener(_focusConversation);
      controller.conversationFocus.addListener(_focusConversation);
    }
  }

  /// A notification or deep link opened a conversation: show it, above
  /// anything pushed on the Conversations section.
  void _focusConversation() {
    _navigators[HomeSection.conversations]!.currentState?.popUntil(
      (route) => route.isFirst,
    );
    _select(HomeSection.conversations);
  }

  /// A file link from chat (or a review): the viewer opens on top of the
  /// Files section, so Back lands on the tree, then on Conversations.
  void _openInFiles(FileLink link) {
    _select(HomeSection.files);
    // A Files section opened just now gets its navigator next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigators[HomeSection.files]!.currentState?.push(
        fileViewRoute(controller, link),
      );
    });
  }

  void _followLink(BuildContext context, String href) {
    followLink(context, controller, href, openFile: _openInFiles);
  }

  void _select(HomeSection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _opened.add(section);
    });
  }

  /// Back closes whatever the visible section pushed (a file, a review),
  /// then returns from Files / Shells to Conversations, then leaves the app.
  void _back() {
    final navigator = _navigators[_section]!.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    } else if (_section != HomeSection.conversations) {
      _select(HomeSection.conversations);
    } else {
      SystemNavigator.pop();
    }
  }

  Widget _root(HomeSection section) => switch (section) {
    HomeSection.files => ExplorerScreen(controller: controller),
    HomeSection.shells => ShellScreen(controller: controller),
    HomeSection.conversations => ChatScreen(controller: controller),
  };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          children: [
            ListenableBuilder(
              listenable: controller.state,
              builder: (context, _) => _SectionBar(
                selected: _section,
                onSelected: _select,
                // Waiting permissions stay visible from Files and Shells.
                conversationAlerts: controller.state.openPermissions.length,
              ),
            ),
            Expanded(
              // The bar above already pads for the status bar.
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                // File viewers pass their own handler (relative links).
                child: MarkdownLinks(
                  onTap: _followLink,
                  child: IndexedStack(
                    index: _section.index,
                    children: [
                      for (final section in HomeSection.values)
                        _opened.contains(section)
                            ? Navigator(
                                key: _navigators[section],
                                onGenerateRoute: (settings) =>
                                    MaterialPageRoute(
                                      settings: settings,
                                      builder: (_) => _root(section),
                                    ),
                              )
                            : const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.conversationFocus.removeListener(_focusConversation);
    super.dispose();
  }
}

class _SectionBar extends StatelessWidget {
  final HomeSection selected;
  final ValueChanged<HomeSection> onSelected;
  final int conversationAlerts;

  const _SectionBar({
    required this.selected,
    required this.onSelected,
    required this.conversationAlerts,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              for (final section in HomeSection.values)
                Expanded(
                  child: _SectionButton(
                    section: section,
                    selected: section == selected,
                    badge: section == HomeSection.conversations &&
                            section != selected
                        ? conversationAlerts
                        : 0,
                    onTap: () => onSelected(section),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionButton extends StatelessWidget {
  final HomeSection section;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  const _SectionButton({
    required this.section,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: Key('section-${section.name}'),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Badge.count(
                count: badge,
                isLabelVisible: badge > 0,
                child: Icon(section.icon, size: 18, color: color),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
