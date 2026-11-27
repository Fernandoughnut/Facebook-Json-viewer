// The About page, reachable from Settings.

import 'package:material_ui/material_ui.dart';

import 'util.dart';

const String appName = 'Indexed';
const String appVersion = '1.5.1';
const int appBuild = 5;
const String appRepoUrl = 'https://github.com/Fernandoughnut/Indexed';
const String appReleasesUrl = '$appRepoUrl/releases';
const String appChangelogUrl = '$appRepoUrl/blob/main/CHANGELOG.md';

String get appVersionLabel => '$appVersion+$appBuild';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About Indexed')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 16),
              Icon(Icons.article_outlined, size: 64, color: cs.primary),
              const SizedBox(height: 12),
              Text(
                appName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Version $appVersionLabel',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'A local viewer for Facebook / Messenger JSON exports. '
                    'Read conversations, search and filter them, show the '
                    'original media inline, and export what you need. '
                    'Everything runs on your device. Nothing is uploaded.',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.code_outlined),
                title: const Text('Source code'),
                subtitle: const Text(appRepoUrl),
                onTap: () => openExternal(appRepoUrl, context),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Downloads and releases'),
                subtitle: const Text(appReleasesUrl),
                onTap: () => openExternal(appReleasesUrl, context),
              ),
              ListTile(
                leading: const Icon(Icons.history_outlined),
                title: const Text('Changelog'),
                subtitle: const Text('Release history on GitHub'),
                onTap: () => openExternal(appChangelogUrl, context),
              ),
              const SizedBox(height: 8),
              Text(
                '- Polarbreed',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
