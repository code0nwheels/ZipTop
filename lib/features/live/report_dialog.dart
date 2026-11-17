import 'package:flutter/material.dart';

import '../../core/api/streams_v2_api.dart';
import '../../core/models/catalog.dart';
import '../../core/models/playback.dart' show ApiException;
import '../../theme.dart';
import '../../ui/zip_spinner.dart';

/// Sends one report for [streamId]; throws with text fit to show on failure.
typedef ReportSender = Future<ReportResult> Function(String streamId, ProblemReport report);

/// Asks what is wrong with [channel] and sends it. On success the dialog
/// closes and a brief confirmation shows; on failure it stays open with the
/// reason, so the viewer can try again.
///
/// Shown over the whole window, full screen included.
Future<void> showReportProblemDialog(
  BuildContext context, {
  required Channel channel,
  required ReportSender send,
  IssueType? initial,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sent = await showDialog<bool>(
    context: context,
    builder: (_) => ReportProblemDialog(channel: channel, send: send, initial: initial),
  );
  if (sent == true) {
    messenger?.showSnackBar(
      const SnackBar(content: Text("Thanks, we've let the team know.")),
    );
  }
}

class ReportProblemDialog extends StatefulWidget {
  const ReportProblemDialog({
    super.key,
    required this.channel,
    required this.send,
    this.initial,
  });

  final Channel channel;
  final ReportSender send;
  final IssueType? initial;

  @override
  State<ReportProblemDialog> createState() => _ReportProblemDialogState();
}

class _ReportProblemDialogState extends State<ReportProblemDialog> {
  final _note = TextEditingController();
  late IssueType? _issue = widget.initial;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final issue = _issue;
    if (issue == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.send(widget.channel.id, ProblemReport(issue, note: _note.text));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = _messageFor(e);
      });
    }
  }

  static String _messageFor(Object error) {
    if (error is ApiException && error.status != null && error.message.isNotEmpty) {
      return error.message;
    }
    // Unreachable server or anything unexpected.
    return StreamsV2Api.reportFailed;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final focusFirst = widget.initial ?? IssueType.values.first;
    return AlertDialog(
      title: const Text('Report a problem'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "What's wrong with ${widget.channel.name.isEmpty ? 'this channel' : widget.channel.name}?",
                style: text.bodyMedium?.copyWith(color: ZipColors.textSecondary),
              ),
              const SizedBox(height: 8),
              RadioGroup<IssueType>(
                groupValue: _issue,
                onChanged: (value) {
                  if (!_sending) setState(() => _issue = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final issue in IssueType.values)
                      RadioListTile<IssueType>(
                        key: ValueKey('report-${issue.wire}'),
                        value: issue,
                        autofocus: issue == focusFirst,
                        enabled: !_sending,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(issue.label),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('report-note'),
                controller: _note,
                enabled: !_sending,
                maxLength: ProblemReport.maxNoteLength,
                minLines: 2,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  labelText: 'Add a note (optional)',
                  hintText: 'Anything that helps the team find the problem',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: ZipColors.danger)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _issue == null || _sending ? null : _send,
          child: _sending ? const ZipSpinner(size: 18) : const Text('Send'),
        ),
      ],
    );
  }
}
