import 'package:flutter/material.dart';

/// One bounded, keyboard-safe surface for settings and short intervention flows.
class CompanionDialog extends StatelessWidget {
  const CompanionDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.busy = false,
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  final bool busy;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 560),
      child: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            Flexible(
              child: Scrollbar(
                child: SingleChildScrollView(
                  // Outlined inputs paint their floating label above the field.
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                  child: child,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: OverflowBar(
                spacing: 12,
                overflowSpacing: 8,
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: actions,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
