import 'package:flutter/material.dart';
import 'companion_dialog.dart';

/// Touch-friendly contextual help, shared by network and peripheral settings.
class CompanionHelpButton extends StatelessWidget {
  const CompanionHelpButton({
    super.key,
    required this.title,
    required this.message,
  });
  final String title, message;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: title,
    icon: const Icon(Icons.info_outline, size: 20),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => CompanionDialog(
        title: title,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Am înțeles'),
          ),
        ],
        child: Text(message),
      ),
    ),
  );
}
