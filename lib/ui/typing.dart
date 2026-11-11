import 'package:flutter/widgets.dart';

/// Whether keyboard focus is in a text field, so single-key shortcuts should
/// let the keystroke through.
///
/// The focus node belongs to the Focus widget EditableText builds inside
/// itself, so this looks up the tree rather than at the focused widget alone.
bool isTypingInTextField() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorStateOfType<EditableTextState>() != null;
}
