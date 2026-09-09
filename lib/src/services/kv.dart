/// Tiny key-value seam so [InstanceStore] can run in widget tests without
/// `flutter_secure_storage`'s platform channel.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class KvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SecureKv implements KvStore {
  final FlutterSecureStorage _storage;
  const SecureKv([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class MemoryKv implements KvStore {
  final Map<String, String> map;
  MemoryKv([Map<String, String>? map]) : map = map ?? {};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}
