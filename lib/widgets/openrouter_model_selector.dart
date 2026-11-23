import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/openrouter_model_catalog.dart';
import '../services/openrouter_service.dart';
import '../services/home_screen_widget_service.dart';
import '../utils/app_theme.dart' as palette;

class OpenRouterModelSelector extends StatefulWidget {
  const OpenRouterModelSelector({
    required this.preferences,
    required this.service,
    super.key,
  });

  final SharedPreferences preferences;
  final OpenRouterService service;

  @override
  State<OpenRouterModelSelector> createState() =>
      _OpenRouterModelSelectorState();
}

class _OpenRouterModelSelectorState extends State<OpenRouterModelSelector> {
  final OpenRouterModelCatalog _catalog = OpenRouterModelCatalog.instance;
  final TextEditingController _search = TextEditingController();
  List<OpenRouterModel> _models = const [];
  String? _selectedId;
  String? _error;
  ModelTestResult? _testResult;
  bool _loading = true;
  bool _testing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.preferences.getString('openrouter_primary_model') ??
        widget.service.activeModelChain.first;
    _search.addListener(_filterChanged);
    _loadModels();
  }

  @override
  void dispose() {
    _search
      ..removeListener(_filterChanged)
      ..dispose();
    super.dispose();
  }

  void _filterChanged() {
    if (mounted) setState(() {});
  }

  List<OpenRouterModel> get _visibleModels {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _models;
    return _models
        .where((model) =>
            model.name.toLowerCase().contains(query) ||
            model.id.toLowerCase().contains(query) ||
            model.category.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _loadModels({bool force = false}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final models = await _catalog.fetchFreeModels(
        apiKey: widget.service.apiKey,
        forceRefresh: force,
      );
      if (!mounted) return;
      if (models.isEmpty) {
        throw const OpenRouterCatalogException(
          'OpenRouter currently has no matching free text-chat models.',
        );
      }

      final availableIds = models.map((model) => model.id).toSet();
      final customIds =
          widget.preferences.getStringList('openrouter_custom_free_models') ??
              const <String>[];
      final validCustomIds =
          customIds.where(availableIds.contains).toList(growable: false);
      final savedPrimary =
          widget.preferences.getString('openrouter_primary_model');
      final String selected =
          _selectedId != null && availableIds.contains(_selectedId)
              ? _selectedId!
              : savedPrimary != null && availableIds.contains(savedPrimary)
                  ? savedPrimary
                  : models.first.id;
      final savedChain =
          widget.preferences.getStringList('openrouter_model_chain') ??
              widget.service.activeModelChain;
      final chain = <String>{
        selected,
        ...savedChain.where(availableIds.contains),
        ...models.map((model) => model.id),
      }.take(3).toList(growable: false);

      // A model can disappear or lose its free variant. Never keep it in the
      // saved failover chain or allow a stale custom ID to remain selectable.
      await widget.preferences
          .setStringList('openrouter_custom_free_models', validCustomIds);
      await widget.preferences.setString('openrouter_primary_model', selected);
      await widget.preferences.setStringList('openrouter_model_chain', chain);
      widget.service.configureModelChain(chain);

      if (!mounted) return;
      setState(() {
        _models = models;
        _selectedId = selected;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _saveSelection() async {
    final selected = _selectedId;
    if (selected == null) return;
    setState(() => _saving = true);
    final availableIds = _models.map((model) => model.id).toSet();
    final chain = <String>{
      selected,
      ...widget.service.activeModelChain.where(
        (id) => id != selected && availableIds.contains(id),
      ),
      ..._models.map((model) => model.id),
    }.take(3).toList(growable: false);
    await widget.preferences.setString('openrouter_primary_model', selected);
    await widget.preferences.setStringList('openrouter_model_chain', chain);
    widget.service.configureModelChain(chain);
    await HomeScreenWidgetService.instance.update(
      status: 'Ready to analyze',
      model: selected,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Model settings updated.')),
    );
  }

  Future<void> _testSelectedModel() async {
    final selected = _selectedId;
    if (selected == null) return;
    setState(() {
      _testing = true;
      _error = null;
      _testResult = null;
    });
    try {
      final result = await _catalog.testModel(
        modelId: selected,
        apiKey: widget.service.apiKey,
      );
      if (!mounted) return;
      setState(() {
        _testResult = result;
        _testing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _testing = false;
      });
    }
  }

  Future<void> _addCustomModel() async {
    final controller = TextEditingController();
    final modelId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a custom free model'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'OpenRouter model ID',
            hintText: 'provider/model-name:free',
            helperText:
                'Must exist in OpenRouter\'s live catalogue and end in :free.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Verify and add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (modelId == null || modelId.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final model = await _catalog.validateCustomFreeModel(
        modelId: modelId,
        apiKey: widget.service.apiKey,
      );
      final customIds =
          widget.preferences.getStringList('openrouter_custom_free_models') ??
              <String>[];
      if (!customIds.contains(model.id)) {
        customIds.add(model.id);
        await widget.preferences
            .setStringList('openrouter_custom_free_models', customIds);
      }
      if (!mounted) return;
      setState(() {
        if (!_models.any((entry) => entry.id == model.id)) {
          _models = [..._models, model]..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
        _selectedId = model.id;
        _loading = false;
      });
      await _saveSelection();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visibleModels;
    final selected =
        _models.where((model) => model.id == _selectedId).firstOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(PhosphorIconsRegular.brain,
                    color: palette.AppColors.dustyLavender, size: 20),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'OpenRouter free models',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  _loading ? 'Loading' : '${_models.length} available',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.AppColors.inkSoft,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh model list',
                  onPressed: _loading ? null : () => _loadModels(force: true),
                  icon: const Icon(PhosphorIconsRegular.arrowsClockwise),
                ),
              ],
            ),
            const Text(
              'Live catalogue · only explicit :free chat models are listed. '
              'The list refreshes on demand and its cache expires after 6 hours.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass),
                labelText: 'Search models',
                hintText: 'Name, provider, or category',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _selectedId != null &&
                      visible.any((model) => model.id == _selectedId)
                  ? _selectedId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Primary model',
                border: OutlineInputBorder(),
              ),
              items: visible
                  .map((model) => DropdownMenuItem(
                        value: model.id,
                        child: Text(
                          model.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: _loading
                  ? null
                  : (value) => setState(() {
                        _selectedId = value;
                        _testResult = null;
                      }),
            ),
            if (selected != null) ...[
              const SizedBox(height: 8),
              Text(
                selected.id,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: palette.AppColors.dustyLavender,
                ),
              ),
              Text(
                '${selected.category} · ${selected.contextLength > 0 ? '${selected.contextLength} context tokens' : 'Context unknown'}'
                '${selected.supportsVision ? ' · Vision input' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.AppColors.inkSoft,
                ),
              ),
              if (selected.description.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  selected.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _saving || _loading ? null : _saveSelection,
                  icon: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(PhosphorIconsRegular.floppyDisk, size: 17),
                  label: const Text('Save model'),
                ),
                OutlinedButton.icon(
                  onPressed: _testing || _loading || _selectedId == null
                      ? null
                      : _testSelectedModel,
                  icon: _testing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(PhosphorIconsRegular.pulse, size: 17),
                  label: Text(_testing ? 'Testing…' : 'Test model'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _addCustomModel,
                  icon: const Icon(PhosphorIconsRegular.plus, size: 17),
                  label: const Text('Add custom free model'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _StatusMessage(
                icon: PhosphorIconsRegular.warningCircle,
                color: theme.colorScheme.error,
                message: _error!,
              ),
            ],
            if (_testResult != null) ...[
              const SizedBox(height: 10),
              _StatusMessage(
                icon: PhosphorIconsRegular.checkCircle,
                color: palette.AppColors.success,
                message:
                    'Model responded in ${_testResult!.latency.inMilliseconds} ms. '
                    'Response: ${_testResult!.output}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
