import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/ui/typing.dart';

/// Mirrors the shell: one Focus at the top takes single-key shortcuts and
/// must leave keys alone while a text field below it has focus.
class _Harness extends StatefulWidget {
  const _Harness({required this.shell, required this.field});

  final FocusNode shell;
  final FocusNode field;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final shortcuts = <LogicalKeyboardKey>[];

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isTypingInTextField()) return KeyEventResult.ignored;
    shortcuts.add(event.logicalKey);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Focus(
          focusNode: widget.shell,
          autofocus: true,
          onKeyEvent: _onKey,
          child: TextField(focusNode: widget.field),
        ),
      ),
    );
  }
}

void main() {
  late FocusNode shell;
  late FocusNode field;

  setUp(() {
    shell = FocusNode(debugLabel: 'shell');
    field = FocusNode(debugLabel: 'field');
  });

  tearDown(() {
    shell.dispose();
    field.dispose();
  });

  _HarnessState state(WidgetTester tester) => tester.state<_HarnessState>(find.byType(_Harness));

  testWidgets('keys typed in a text field are not taken as shortcuts', (tester) async {
    await tester.pumpWidget(_Harness(shell: shell, field: field));
    field.requestFocus();
    await tester.pump();

    expect(isTypingInTextField(), isTrue);
    // The old check looked only at the focused widget, which is the Focus
    // EditableText builds, so it never saw the text field.
    expect(FocusManager.instance.primaryFocus?.context?.widget is EditableText, isFalse);

    for (final key in [
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyG, // opens the guide
      LogicalKeyboardKey.space, // play/pause
      LogicalKeyboardKey.digit1, // channel number entry
      LogicalKeyboardKey.digit0,
    ]) {
      expect(await tester.sendKeyEvent(key), isFalse, reason: '$key was swallowed');
    }
    expect(state(tester).shortcuts, isEmpty);
  });

  testWidgets('shortcuts still work when no text field has focus', (tester) async {
    await tester.pumpWidget(_Harness(shell: shell, field: field));
    shell.requestFocus();
    await tester.pump();

    expect(isTypingInTextField(), isFalse);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyG), isTrue);
    expect(state(tester).shortcuts, [LogicalKeyboardKey.keyG]);
  });
}
