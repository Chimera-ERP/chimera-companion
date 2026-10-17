import 'package:flutter/material.dart';
import 'companion_app_bar.dart';

final debugMessages = ValueNotifier<List<String>>([]);
void debugLog(String message) {
  final now = TimeOfDay.now();
  final stamp =
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  final next = [...debugMessages.value, '$stamp  $message'];
  debugMessages.value = next.length > 200
      ? next.sublist(next.length - 200)
      : next;
}

class DebugScaffold extends StatelessWidget {
  const DebugScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.showDebug = false,
    this.busy = false,
  });
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final bool showDebug;
  final bool busy;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: CompanionAppBar(
      title: Text(title),
      actions: actions ?? [],
      busy: busy,
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(child: body),
          if (showDebug) const DebugPanel(),
        ],
      ),
    ),
  );
}

class DebugPanel extends StatefulWidget {
  const DebugPanel({super.key});
  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  final _scroll = ScrollController();
  bool _expanded = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Color(0xff10141c),
      border: Border(top: BorderSide(color: Color(0xff293140))),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              const SizedBox(width: 16),
              const Icon(Icons.terminal, size: 16),
              const SizedBox(width: 8),
              const Text('Debug', style: TextStyle(fontSize: 12)),
              const Spacer(),
              IconButton(
                tooltip: 'Șterge mesaje',
                onPressed: () => debugMessages.value = [],
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
              IconButton(
                tooltip: _expanded ? 'Restrânge debug' : 'Extinde debug',
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_more : Icons.expand_less,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
        if (_expanded)
          SizedBox(
            height: 84,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: debugMessages,
              builder: (context, messages, _) => Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  itemCount: messages.isEmpty ? 1 : messages.length,
                  itemBuilder: (_, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SelectableText(
                      messages.isEmpty
                          ? 'Mesajele operațiunilor apar aici.'
                          : messages[messages.length - 1 - index],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xffb6c4d9),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
