import 'package:flutter/material.dart';
import 'app_updates.dart';

/// Lives above the Navigator so every route shares the same hardware update gate.
class CompanionUpdateScope extends InheritedWidget {
  const CompanionUpdateScope({
    super.key,
    required this.isBusy,
    required this.setUpdating,
    required super.child,
  });
  final bool Function() isBusy;
  final void Function(bool) setUpdating;
  static CompanionUpdateScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CompanionUpdateScope>();
  @override
  bool updateShouldNotify(CompanionUpdateScope oldWidget) => true;
}

class CompanionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const CompanionAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.busy = false,
    this.autoCheck = false,
    this.leading,
  });
  final Widget title;
  final List<Widget> actions;
  final bool busy, autoCheck;
  final Widget? leading;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) {
    final scope = CompanionUpdateScope.of(context);
    return AppBar(
      leading: leading,
      title: title,
      actions: [
        ...actions,
        CompanionUpdateButton(
          autoCheck: autoCheck,
          isBusy: () => busy || (scope?.isBusy() ?? false),
          setUpdating: (value) => scope?.setUpdating(value),
        ),
      ],
    );
  }
}
