import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('update 原子读改写，并合并默认值', () async {
    final store = SettingsStore.instance;
    await store.update((s) => s['lastSelectedTag'] = 'foo');
    final loaded = await store.load();
    expect(loaded['lastSelectedTag'], 'foo');
    // 未改动的字段仍按默认值合并
    expect(loaded['localPort'], 2080);
    expect(loaded['dnsNameservers'], ['223.5.5.5', '119.29.29.29']);
  });

  test('reset 回到默认值', () async {
    final store = SettingsStore.instance;
    await store.update((s) => s['localPort'] = 9999);
    expect((await store.load())['localPort'], 9999);
    await store.reset();
    expect((await store.load())['localPort'], 2080);
  });
}
