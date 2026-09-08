import 'package:flutter/material.dart';

import '../danmaku/service/danmaku_service.dart';
import '../danmaku/settings/danmaku_display_settings.dart';
import '../danmaku/source/danmaku_source_registry.dart';
import '../danmaku/source/danmaku_source_store.dart';
import '../danmaku/source/danmu_api_source.dart';
import '../l10n/app_localizations.dart';

class DanmakuSettingsScreen extends StatefulWidget {
  const DanmakuSettingsScreen({super.key, this.service});

  final DanmakuService? service;

  @override
  State<DanmakuSettingsScreen> createState() => _DanmakuSettingsScreenState();
}

class _DanmakuSettingsScreenState extends State<DanmakuSettingsScreen> {
  late final DanmakuService _service =
      widget.service ?? DanmakuService.instance;
  bool _loading = true;
  bool _enabled = true;
  List<DanmakuSourceConfig> _sources = const [];
  DanmakuDisplaySettings _display = const DanmakuDisplaySettings();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.init();
    final display = await DanmakuDisplaySettingsStore.load();
    if (!mounted) return;
    setState(() {
      _enabled = _service.enabled;
      _sources = List.of(_service.configs)
        ..sort((a, b) => b.priority.compareTo(a.priority));
      _display = display;
      _loading = false;
    });
  }

  Future<void> _saveSources(List<DanmakuSourceConfig> sources) async {
    setState(() => _sources = sources);
    await _service.reconfigure(sources);
  }

  Future<void> _saveDisplay(DanmakuDisplaySettings display) async {
    setState(() => _display = display);
    await DanmakuDisplaySettingsStore.save(display);
  }

  Future<void> _editSource([DanmakuSourceConfig? existing]) async {
    final result = await showDialog<DanmakuSourceConfig>(
      context: context,
      builder: (context) => _SourceDialog(existing: existing),
    );
    if (result == null) return;
    var next = List<DanmakuSourceConfig>.of(_sources);
    final index = next.indexWhere((item) => item.id == result.id);
    if (index < 0) {
      next.add(result.copyWith(priority: next.length));
    } else {
      next[index] = result;
    }
    await _saveSources(next);
  }

  Future<void> _deleteSource(DanmakuSourceConfig source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Delete danmaku source?'),
        content: AppText('Remove “${source.name}”?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const AppText('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _saveSources(
        _sources.where((item) => item.id != source.id).toList(),
      );
    }
  }

  Future<void> _move(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    var next = List<DanmakuSourceConfig>.of(_sources);
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    next = [
      for (var i = 0; i < next.length; i++)
        next[i].copyWith(priority: next.length - i),
    ];
    await _saveSources(next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const AppText('Danmaku')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _loading ? null : () => _editSource(),
      icon: const Icon(Icons.add),
      label: const AppText('Add source'),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              _Section(title: 'General'),
              SwitchListTile(
                secondary: const Icon(Icons.subtitles),
                title: const AppText('Show danmaku'),
                subtitle: const AppText('Global switch for bullet comments'),
                value: _enabled,
                onChanged: (value) async {
                  setState(() => _enabled = value);
                  await _service.setEnabled(value);
                },
              ),
              const Divider(),
              _Section(title: 'Sources'),
              if (_sources.isEmpty)
                const ListTile(
                  leading: Icon(Icons.cloud_off),
                  title: AppText('No danmaku sources'),
                  subtitle: AppText(
                    'Add a danmu_api deployment to get started',
                  ),
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _sources.length,
                  onReorderItem: _move,
                  itemBuilder: (context, index) {
                    final source = _sources[index];
                    return ListTile(
                      key: ValueKey(source.id),
                      leading: Switch(
                        value: source.enabled,
                        onChanged: (value) {
                          final next = List<DanmakuSourceConfig>.of(_sources);
                          next[index] = source.copyWith(enabled: value);
                          _saveSources(next);
                        },
                      ),
                      title: AppText(source.name),
                      subtitle: AppText(
                        '${source.baseUrl}${source.token.isEmpty ? '' : ' · token set'} · priority ${source.priority}',
                      ),
                      trailing: Wrap(
                        spacing: 0,
                        children: [
                          IconButton(
                            tooltip: context.tr('Edit'),
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _editSource(source),
                          ),
                          IconButton(
                            tooltip: context.tr('Delete'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteSource(source),
                          ),
                          const Icon(Icons.drag_handle),
                        ],
                      ),
                    );
                  },
                ),
              const Divider(),
              _Section(title: 'Appearance'),
              _SliderTile(
                label: 'Font size',
                value: _display.fontSize,
                min: 12,
                max: 48,
                divisions: 18,
                valueLabel: '${_display.fontSize.round()} px',
                onChanged: (v) => _saveDisplay(_display.copyWith(fontSize: v)),
              ),
              _SliderTile(
                label: 'Opacity',
                value: _display.opacity,
                min: .1,
                max: 1,
                divisions: 9,
                valueLabel: '${(_display.opacity * 100).round()}%',
                onChanged: (v) => _saveDisplay(_display.copyWith(opacity: v)),
              ),
              _SliderTile(
                label: 'Display area',
                value: _display.displayArea,
                min: .25,
                max: 1,
                divisions: 3,
                valueLabel: '${(_display.displayArea * 100).round()}%',
                onChanged: (v) =>
                    _saveDisplay(_display.copyWith(displayArea: v)),
              ),
              _SliderTile(
                label: 'Scroll speed',
                value: _display.scrollSpeed,
                min: .5,
                max: 2,
                divisions: 15,
                valueLabel: '${_display.scrollSpeed.toStringAsFixed(1)}×',
                onChanged: (v) =>
                    _saveDisplay(_display.copyWith(scrollSpeed: v)),
              ),
              SwitchListTile(
                title: const AppText('Scrolling comments'),
                value: _display.showScroll,
                onChanged: (v) =>
                    _saveDisplay(_display.copyWith(showScroll: v)),
              ),
              SwitchListTile(
                title: const AppText('Top comments'),
                value: _display.showTop,
                onChanged: (v) => _saveDisplay(_display.copyWith(showTop: v)),
              ),
              SwitchListTile(
                title: const AppText('Bottom comments'),
                value: _display.showBottom,
                onChanged: (v) =>
                    _saveDisplay(_display.copyWith(showBottom: v)),
              ),
              ListTile(
                leading: const Icon(Icons.block),
                title: const AppText('Blocked words'),
                subtitle: AppText(
                  _display.blockedWords.isEmpty
                      ? 'None'
                      : '${_display.blockedWords.length} words',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _editBlockedWords,
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const AppText('Clear danmaku cache'),
                subtitle: const AppText(
                  'Downloaded comments will be fetched again when needed',
                ),
                onTap: _clearCache,
              ),
            ],
          ),
  );

  Future<void> _editBlockedWords() async {
    final controller = TextEditingController(
      text: _display.blockedWords.join('\n'),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Blocked words'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            minLines: 6,
            maxLines: 12,
            decoration: InputDecoration(
              hintText: context.tr('One word or phrase per line'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const AppText('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await _saveDisplay(
        _display.copyWith(
          blockedWords: controller.text.split(RegExp(r'[\r\n]+')),
        ),
      );
    }
    controller.dispose();
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Clear danmaku cache?'),
        content: const AppText(
          'All downloaded comments will be removed. Source settings are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const AppText('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.clearCache();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: AppText('Danmaku cache cleared')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText('Could not clear danmaku cache: $error')),
      );
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: AppText(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });
  final String label;
  final double value, min, max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Row(
      children: [
        Expanded(child: AppText(label)),
        AppText(valueLabel),
      ],
    ),
    subtitle: Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      label: valueLabel,
      onChanged: onChanged,
    ),
  );
}

class _SourceDialog extends StatefulWidget {
  const _SourceDialog({this.existing});
  final DanmakuSourceConfig? existing;
  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _testing = false;
  String? _testMessage;
  DanmakuCancelToken? _testCancelToken;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? 'danmu_api');
    _url = TextEditingController(text: widget.existing?.baseUrl ?? '');
    _token = TextEditingController(text: widget.existing?.token ?? '');
  }

  String? _validateUrl(String? value) {
    try {
      final normalized = DanmuApiConfig.normalizedBaseUrl(value ?? '');
      final uri = Uri.parse(normalized);
      if (uri.host.toLowerCase() == 'github.com' ||
          uri.path.toLowerCase().endsWith('.git')) {
        return 'Enter the deployed danmu_api service URL, not its repository';
      }
      return null;
    } on ArgumentError {
      return 'Enter a valid http(s) service URL';
    }
  }

  DanmakuSourceConfig _value() => DanmakuSourceConfig(
    id: widget.existing?.id ?? DanmakuSourceConfig.newId(),
    name: _name.text.trim(),
    baseUrl: DanmuApiConfig.normalizedBaseUrl(_url.text),
    token: _token.text.trim(),
    enabled: widget.existing?.enabled ?? true,
    priority: widget.existing?.priority ?? 0,
  );

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    _testCancelToken?.cancel();
    final cancelToken = DanmakuCancelToken();
    _testCancelToken = cancelToken;
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      final value = _value();
      await DanmuApiSource(
        DanmuApiConfig(
          baseUrl: value.baseUrl,
          token: value.token,
          sourceId: value.id,
          displayName: value.name,
        ),
      ).verifyConnectivity(cancelToken: cancelToken);
      if (mounted) setState(() => _testMessage = 'Connection successful');
    } catch (error) {
      if (mounted) setState(() => _testMessage = 'Connection failed: $error');
    } finally {
      if (mounted && identical(_testCancelToken, cancelToken)) {
        setState(() => _testing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: AppText(
      widget.existing == null ? 'Add danmaku source' : 'Edit danmaku source',
    ),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: InputDecoration(labelText: context.tr('Name')),
                validator: (v) => v == null || v.trim().isEmpty
                    ? context.tr('Name is required')
                    : null,
              ),
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: context.tr('Base URL'),
                  hintText: 'https://danmu.example.com',
                ),
                validator: _validateUrl,
              ),
              TextFormField(
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.tr('Token (optional)'),
                ),
              ),
              if (_testMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      _testMessage!,
                      style: TextStyle(
                        color: _testMessage!.startsWith('Connection successful')
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _testing ? null : () => Navigator.pop(context),
        child: const AppText('Cancel'),
      ),
      OutlinedButton(
        onPressed: _testing ? null : _test,
        child: _testing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const AppText('Test connection'),
      ),
      FilledButton(
        onPressed: _testing
            ? null
            : () {
                if (_formKey.currentState!.validate()) {
                  Navigator.pop(context, _value());
                }
              },
        child: const AppText('Save'),
      ),
    ],
  );

  @override
  void dispose() {
    _testCancelToken?.cancel();
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }
}
