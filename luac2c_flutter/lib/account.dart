// 本地账号 + 用户指纹
//
// 客户端没有服务端，账号库就在本机（%APPDATA%\luac2c\users.json），
// 口令只保存 salt 后的 SHA-256 校验值，不保存明文。
//
// 账号登录后，客户端会把 uid 通过 luac2c --fingerprint 传下去，
// 生成的二进制里就带上这个账号的指纹：拿到副本跑
//   luac2c --who prog.exe
// 就能知道它是谁的。指纹是 uid 折叠出来的一个 32 位数，
// 二进制里没有任何明文标识（详见 luac2c.c 的 Watermarking 说明）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'sha256.dart';

/// FNV-1a 32：与 luac2c.c 的 wm_fold() 逐位一致，
/// 所以客户端显示的指纹和生成物里嵌的是同一个数。
int foldFingerprint(String uid) {
  var h = 2166136261;
  for (final b in utf8.encode(uid)) {
    h = (h ^ b) & 0xFFFFFFFF;
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h == 0 ? 0xA5A5A5A5 : h; // 0 在生成器里代表"没有指纹"
}

class AccountCtl extends ChangeNotifier {
  AccountCtl._();
  static final AccountCtl I = AccountCtl._();

  String? uid; // 账号唯一标识（指纹由它派生）
  String? name; // 登录名
  bool remember = true;

  bool get loggedIn => uid != null && uid!.isNotEmpty;

  /// 指纹字，8 位大写十六进制
  String get fingerprint => loggedIn
      ? foldFingerprint(uid!).toRadixString(16).toUpperCase().padLeft(8, '0')
      : '';

  static String get _dir {
    final app = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        '.';
    return Platform.isWindows ? '$app\\luac2c' : '$app/.luac2c';
  }

  /// 对外（"我的"页展示用）：账号库所在目录
  static String get dir => _dir;

  static String _p(String f) =>
      '$_dir${Platform.isWindows ? '\\' : '/'}$f';

  File get _usersFile => File(_p('users.json'));
  File get _sessionFile => File(_p('session.json'));

  String _rnd(int bytes) {
    final r = Random.secure();
    final b = List<int>.generate(bytes, (_) => r.nextInt(256));
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  // ------------------------------------------------------------ 持久化
  /// 注意必须返回**可变**列表：首次注册（还没有账号库）时调用方要往里加账号，
  /// 返回 const [] 会在 add 时抛 "Cannot add to an unmodifiable list"。
  Future<List<Map<String, dynamic>>> _readUsers() async {
    try {
      final f = _usersFile;
      if (!f.existsSync()) return <Map<String, dynamic>>[];
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['users'] is List) {
        return (j['users'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {/* 文件坏了就当空库 */}
    return <Map<String, dynamic>>[];
  }

  Future<bool> _writeUsers(List<Map<String, dynamic>> u) async {
    try {
      final d = Directory(_dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      await _usersFile.writeAsString(jsonEncode({'users': u}));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 启动时恢复"记住我"的会话
  Future<void> load() async {
    try {
      final f = _sessionFile;
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['uid'] is String) {
        uid = j['uid'] as String;
        name = (j['name'] as String?) ?? uid;
        remember = j['remember'] != false;
        notifyListeners();
      }
    } catch (_) {/* 会话损坏就当未登录 */}
  }

  Future<void> _saveSession() async {
    try {
      final d = Directory(_dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      if (loggedIn && remember) {
        await _sessionFile.writeAsString(
            jsonEncode({'uid': uid, 'name': name, 'remember': true}));
      } else {
        if (_sessionFile.existsSync()) _sessionFile.deleteSync();
      }
    } catch (_) {/* 写不进去不影响本次登录 */}
  }

  // ------------------------------------------------------------ 业务
  /// 注册。返回 null 表示成功，否则是给用户看的错误文案。
  Future<String?> register(String user, String pwd) async {
    final u = user.trim();
    if (u.length < 2) return '账号至少 2 个字符';
    if (pwd.length < 6) return '密码至少 6 位';
    final all = await _readUsers();
    if (all.any((e) => (e['name'] ?? '') == u)) return '该账号已存在，请直接登录';
    final salt = _rnd(16);
    all.add({
      'uid': 'U-${_rnd(4).toUpperCase()}',
      'name': u,
      'salt': salt,
      'verifier': sha256Hex('$salt:$pwd'),
      'at': DateTime.now().toIso8601String(),
    });
    if (!await _writeUsers(all)) return '账号库写入失败（检查 %APPDATA%\\luac2c 权限）';
    return login(u, pwd);
  }

  /// 登录。返回 null 表示成功。
  Future<String?> login(String user, String pwd) async {
    final u = user.trim();
    if (u.isEmpty || pwd.isEmpty) return '请输入账号和密码';
    final all = await _readUsers();
    Map<String, dynamic>? hit;
    for (final e in all) {
      if ((e['name'] ?? '') == u) {
        hit = e;
        break;
      }
    }
    if (hit == null) return '账号不存在，请先注册';
    final want = hit['verifier'] as String? ?? '';
    final got = sha256Hex('${hit['salt'] as String? ?? ''}:$pwd');
    if (want.isEmpty || want != got) return '密码不正确';
    uid = hit['uid'] as String? ?? 'U-00000000';
    name = u;
    await _saveSession();
    notifyListeners();
    return null;
  }

  Future<void> logout() async {
    uid = null;
    name = null;
    await _saveSession();
    notifyListeners();
  }

  Future<void> setRemember(bool v) async {
    remember = v;
    await _saveSession();
    notifyListeners();
  }

  /// 本机已有账号数（给"我的"页做副标题）
  Future<int> userCount() async => (await _readUsers()).length;
}
