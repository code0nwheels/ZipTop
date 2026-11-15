import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import 'update_service.dart';

/// Offers an update, downloads it with progress, hands over to it, then asks
/// [onInstall] to close the app so the update can take its place. The offer
/// is checked with the server before each download, since it may be an old
/// one remembered from before a later release.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.service,
    required this.update,
    required this.onInstall,
  });

  final UpdateService service;
  final UpdateInfo update;

  /// Called once the update has been started.
  final Future<void> Function() onInstall;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  final _cancel = CancelToken();
  late UpdateInfo _update = widget.update;
  bool _downloading = false;
  bool _upToDate = false;
  double? _progress;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });
    try {
      final latest = await widget.service.refresh(_update);
      if (!mounted || _cancel.isCancelled) return;
      if (latest == null) {
        setState(() {
          _downloading = false;
          _upToDate = true;
        });
        return;
      }
      setState(() => _update = latest);
      final file = await widget.service.download(
        _update,
        cancel: _cancel,
        onProgress: (fraction) {
          if (mounted) setState(() => _progress = fraction);
        },
      );
      await widget.service.install(file);
      await widget.onInstall();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || !mounted) return;
      setState(() {
        _downloading = false;
        _error = "Couldn't download the update. ${e.message ?? ''}".trim();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = "Couldn't start the update. $e";
      });
    }
  }

  @override
  void dispose() {
    if (!_cancel.isCancelled) _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final percent = _progress == null ? null : (_progress! * 100).round();
    return AlertDialog(
      title: Text(_upToDate ? 'ZipTop is up to date' : 'ZipTop ${_update.version} is available'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 360, maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _upToDate
                  ? 'You have ${widget.service.currentVersion}, the latest release.'
                  : _downloading
                  ? 'Downloading${percent == null ? '…' : ' $percent%'}'
                  : 'You have ${widget.service.currentVersion}. ZipTop will close while the '
                      'update installs; anything being recorded will stop.\n\n'
                      'Not now? The Update button stays in the sidebar.',
            ),
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: ZipColors.warnText)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (!_downloading && !_upToDate) widget.service.dismiss(_update);
            Navigator.of(context).pop();
          },
          child: Text(_downloading ? 'Cancel' : (_upToDate ? 'Close' : 'Later')),
        ),
        if (!_downloading && !_upToDate)
          FilledButton(
            onPressed: _start,
            child: Text(_error == null ? 'Update now' : 'Try again'),
          ),
      ],
    );
  }
}
