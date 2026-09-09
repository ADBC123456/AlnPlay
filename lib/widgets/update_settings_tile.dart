import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_service.dart';
import '../l10n/app_localizations.dart';

String _releaseBody(BuildContext context, UpdateInfo release) {
  final date = release.publishedAt == null
      ? ''
      : '${context.tr('Published')}: ${release.publishedAt!.toLocal().toString().split(' ').first}\n\n';
  final ios = Platform.isIOS
      ? '\n\n${context.tr('Download the IPA from the release page.')}'
      : '';
  return '$date${release.notes.isEmpty ? context.tr('A new version is ready.') : release.notes}$ios';
}

/// Standalone settings entry. The settings screen can place this tile without
/// taking a dependency on update scheduling or GitHub details.
class UpdateSettingsTile extends StatefulWidget {
  const UpdateSettingsTile({super.key, this.service});
  final UpdateService? service;
  @override
  State<UpdateSettingsTile> createState() => _UpdateSettingsTileState();
}

/// Optional root wrapper for the once-per-day background check. The wrapper
/// never blocks or changes the child tree; it only shows an update dialog when
/// an automatic check finds a newer stable release.
class UpdateCheckHost extends StatefulWidget {
  const UpdateCheckHost({super.key, required this.child, this.service});
  final Widget child;
  final UpdateService? service;
  @override
  State<UpdateCheckHost> createState() => _UpdateCheckHostState();
}

class _UpdateCheckHostState extends State<UpdateCheckHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    final service = widget.service ?? UpdateService();
    final result = await service.check();
    if (!mounted || !result.hasUpdate) return;
    if (!await service.shouldNotify(result.release!)) return;
    final release = result.release!;
    await service.markNotified(release);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${context.tr('New version available')}: ${release.version}',
        ),
        content: SingleChildScrollView(
          child: Text(_releaseBody(context, release)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              launchUrl(
                Uri.parse(release.url),
                mode: LaunchMode.externalApplication,
              );
            },
            child: const AppText('View release'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _UpdateSettingsTileState extends State<UpdateSettingsTile> {
  bool _busy = false;
  String? _installed;
  @override
  void initState() {
    super.initState();
    (widget.service ?? UpdateService()).installedVersion.then((v) {
      if (mounted) setState(() => _installed = v);
    });
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final result = await (widget.service ?? UpdateService()).check(force: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.hasUpdate) {
      final release = result.release!;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            '${context.tr('New version available')}: ${release.version}',
          ),
          content: SingleChildScrollView(
            child: Text(_releaseBody(context, release)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: AppText('Later'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                launchUrl(
                  Uri.parse(release.url),
                  mode: LaunchMode.externalApplication,
                );
              },
              child: AppText('View release'),
            ),
          ],
        ),
      );
    } else if (result.status == UpdateStatus.upToDate) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText('You are using the latest version.')),
      );
    } else {
      final message = switch (result.status) {
        UpdateStatus.rateLimited =>
          'GitHub rate limit reached. Please try again later.',
        UpdateStatus.notFound => 'No public release is available yet.',
        UpdateStatus.invalidResponse =>
          'The installed version or release information could not be verified.',
        _ => 'Could not check for updates.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(message)));
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.system_update_outlined),
    title: const AppText('Check for updates'),
    subtitle: _installed == null
        ? const AppText('GitHub release')
        : Text('${context.tr('Installed version')}: $_installed'),
    trailing: _busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.chevron_right),
    onTap: _busy ? null : _check,
  );
}
