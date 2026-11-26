// Settings must flush debounced writes and allow local PIN recovery.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/settings.dart';

void main() {
  test(
    'PIN can be set, checked, reset, and the reset is written immediately',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'indexed_settings_test_',
      );
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final settings = AppSettings(configDir: dir.path);
      addTearDown(settings.dispose);
      await settings.load();

      settings.setPin('1234');
      expect(settings.lockEnabled, isTrue);
      expect(settings.pinMatches('1234'), isTrue);
      expect(settings.pinMatches('9999'), isFalse);

      await settings.resetPin();
      expect(settings.lockEnabled, isFalse);
      expect(settings.lockHash, isEmpty);
      expect(settings.lockSalt, isEmpty);
      expect(settings.pinMatches('anything'), isTrue);

      final state = File('${dir.path}/state.json');
      expect(state.existsSync(), isTrue);
      final saved = jsonDecode(state.readAsStringSync()) as Map;
      expect(saved['lockEnabled'], isFalse);
      expect(saved['lockHash'], '');
      expect(File('${dir.path}/state.json.tmp').existsSync(), isFalse);
    },
  );

  test('saved searches replace by name and survive a reload', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_presets_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();

    settings.savePreset(
      const SearchPreset(
        name: 'photos',
        query: '',
        sender: 'Ana',
        mediaOnly: true,
        regex: false,
        caseSensitive: false,
        sort: 'newest',
      ),
    );
    settings.savePreset(
      const SearchPreset(
        name: 'photos',
        query: 'beach',
        sender: 'Ana',
        mediaOnly: true,
        regex: false,
        caseSensitive: false,
        sort: 'oldest',
      ),
    );
    expect(settings.presets, hasLength(1));
    expect(settings.presets.single.query, 'beach');
    expect(settings.presets.single.summary, contains('beach'));

    await settings.flush();
    final reloaded = AppSettings(configDir: dir.path);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.presets, hasLength(1));
    expect(reloaded.presets.single.name, 'photos');
    expect(reloaded.presets.single.sort, 'oldest');
    expect(reloaded.showActivityRail, isFalse);
  });

  test('design style persists and switches ThemeData.useMaterial3', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_design_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.material3, isTrue);
    expect(settings.themeFor(Brightness.light).useMaterial3, isTrue);

    settings.material3 = false;
    expect(settings.themeFor(Brightness.light).useMaterial3, isFalse);
    settings.material3 = true;
    expect(settings.themeFor(Brightness.light).useMaterial3, isTrue);
    settings.material3 = false;
    await settings.flush();

    final reloaded = AppSettings(configDir: dir.path);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.material3, isFalse);
    expect(reloaded.themeFor(Brightness.light).useMaterial3, isFalse);
  });

  test('people filters visibility persists', () async {
    final dir = await Directory.systemTemp.createTemp(
      'indexed_people_filters_test_',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.showPeopleFilters, isTrue);
    settings.showPeopleFilters = false;
    await settings.flush();

    final reloaded = AppSettings(configDir: dir.path);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.showPeopleFilters, isFalse);
  });

  test('archived and removed chat keys persist', () async {
    final dir = await Directory.systemTemp.createTemp(
      'indexed_chat_state_test_',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();

    settings.archivedChats.add('chat-a');
    settings.removedChats.add('chat-b');
    await settings.flush();

    final reloaded = AppSettings(configDir: dir.path);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.archivedChats, contains('chat-a'));
    expect(reloaded.removedChats, contains('chat-b'));
  });

  test(
    'aliases and notes reload from their values, not MapEntry.toString()',
    () async {
      final dir = await Directory.systemTemp.createTemp('indexed_text_test_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final settings = AppSettings(configDir: dir.path);
      addTearDown(settings.dispose);
      await settings.load();

      settings.aliases['Ana'] = 'Anna';
      settings.notes['chat|msg'] = 'remember this';
      await settings.flush();

      final reloaded = AppSettings(configDir: dir.path);
      addTearDown(reloaded.dispose);
      await reloaded.load();

      expect(reloaded.aliases['Ana'], 'Anna');
      expect(reloaded.notes['chat|msg'], 'remember this');
    },
  );

  test('breadcrumbs are written synchronously to the error log', () async {
    final dir = await Directory.systemTemp.createTemp(
      'indexed_breadcrumb_test_',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);

    settings.logBreadcrumb('opened a chat');

    final log = File(settings.logPath).readAsStringSync();
    expect(log, contains('[breadcrumb] opened a chat'));
  });

  test('chat chrome options persist', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_chrome_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.showActivityRail, isFalse);
    expect(settings.immersiveMode, isFalse);
    expect(settings.showDatePill, isTrue);
    expect(settings.autoHideTopBar, isTrue);
    expect(settings.showIndexScrollbar, isTrue);
    expect(settings.groupTimesByMinute, isTrue);
    settings.showDatePill = false;
    settings.autoHideTopBar = false;
    settings.showIndexScrollbar = false;
    settings.groupTimesByMinute = false;
    settings.immersiveMode = true;
    await settings.flush();

    final reloaded = AppSettings(configDir: dir.path);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.showActivityRail, isFalse);
    expect(reloaded.immersiveMode, isTrue);
    expect(reloaded.showDatePill, isFalse);
    expect(reloaded.autoHideTopBar, isFalse);
    expect(reloaded.showIndexScrollbar, isFalse);
    expect(reloaded.groupTimesByMinute, isFalse);
  });

  test(
    'old activity-rail default is turned off once, then user choice wins',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'indexed_rail_migration_test_',
      );
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final state = File('${dir.path}/state.json');
      state.writeAsStringSync(jsonEncode({'showActivityRail': true}));

      final settings = AppSettings(configDir: dir.path);
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.showActivityRail, isFalse);
      expect(settings.activityRailDefaultApplied, isTrue);

      settings.update(() => settings.showActivityRail = true);
      await settings.flush();

      final reloaded = AppSettings(configDir: dir.path);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.showActivityRail, isTrue);
    },
  );
}
