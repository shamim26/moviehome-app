import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'moviebox_crypto.dart';

class MovieBoxSession {
  MovieBoxSession({
    required this.token,
    this.userId,
    this.expiresAt,
    required this.createdAt,
  });

  final String token;
  final String? userId;
  final int? expiresAt;
  final int createdAt;

  bool get isValid {
    if (token.trim().isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expiresAt != null) {
      return (now + 60) < expiresAt!;
    }
    return now < (createdAt + (7 * 24 * 3600));
  }

  static (String?, int?) parseJwtClaims(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return (null, null);
      var payloadB64 = parts[1];
      final padLen = (4 - (payloadB64.length % 4)) % 4;
      payloadB64 = payloadB64 + ('=' * padLen);
      final decodedBytes = base64Url.decode(payloadB64);
      final map = jsonDecode(utf8.decode(decodedBytes)) as Map<String, dynamic>;
      final uid = map['userId']?.toString() ?? map['uid']?.toString() ?? map['sub']?.toString();
      final expVal = map['exp'];
      final exp = expVal is int ? expVal : int.tryParse(expVal?.toString() ?? '');
      return (uid, exp);
    } catch (_) {
      return (null, null);
    }
  }

  factory MovieBoxSession.fromToken(String token, [String? explicitUid]) {
    final (jwtUid, jwtExp) = parseJwtClaims(token);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return MovieBoxSession(
      token: token,
      userId: explicitUid ?? jwtUid,
      expiresAt: jwtExp,
      createdAt: now,
    );
  }
}

class MovieBoxSessionManager {
  MovieBoxSessionManager._();
  static final MovieBoxSessionManager instance = MovieBoxSessionManager._();

  static const String _prefTokenKey = 'moviebox_auth_token';
  static const String _prefUserIdKey = 'moviebox_user_id';
  static const String _prefExpKey = 'moviebox_expires_at';
  static const String _prefCreatedKey = 'moviebox_created_at';

  static const String host = 'https://api.inmoviebox.com';

  MovieBoxSession? _cachedSession;
  String? _userAgent;
  String? _clientInfo;
  String? _spoofedIp;

  String get userAgent {
    _ensureDeviceInfo();
    return _userAgent!;
  }

  String get clientInfo {
    _ensureDeviceInfo();
    return _clientInfo!;
  }

  String get spoofedIp {
    _ensureDeviceInfo();
    return _spoofedIp!;
  }

  void _ensureDeviceInfo() {
    if (_userAgent == null || _clientInfo == null) {
      final (ua, info) = MovieBoxCrypto.generateClientInfoAndUa();
      _userAgent = ua;
      _clientInfo = info;
      _spoofedIp = MovieBoxCrypto.randomSpoofedIp();
    }
  }

  Future<String?> getToken() async {
    if (_cachedSession != null && _cachedSession!.isValid) {
      return _cachedSession!.token;
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_prefTokenKey);
    final uid = prefs.getString(_prefUserIdKey);
    final exp = prefs.getInt(_prefExpKey);
    final created = prefs.getInt(_prefCreatedKey) ?? 0;

    if (token != null && token.isNotEmpty) {
      final session = MovieBoxSession(
        token: token,
        userId: uid,
        expiresAt: exp,
        createdAt: created,
      );
      if (session.isValid) {
        _cachedSession = session;
        return session.token;
      }
    }

    return await _fetchFreshSession();
  }

  Future<String?> _fetchFreshSession() async {
    _ensureDeviceInfo();
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);

    try {
      const path = '/wefeed-mobile-bff/user-api/visitor-login';
      const url = '$host$path';
      const body = '{}';

      final headers = MovieBoxCrypto.buildSignedHeaders(
        method: 'POST',
        url: url,
        body: body,
        authToken: null,
        userAgent: _userAgent!,
        clientInfo: _clientInfo!,
        spoofedIp: _spoofedIp!,
      );

      final req = await client.postUrl(Uri.parse(url));
      headers.forEach((k, v) => req.headers.set(k, v));
      req.write(body);

      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final json = jsonDecode(text) as Map<String, dynamic>;

      final token = json['data']?['token']?.toString();
      if (token == null || token.isEmpty) {
        debugPrint('[MovieBox] visitor-login missing token: $text');
        return null;
      }

      final uid = json['data']?['uid']?.toString() ?? json['data']?['userId']?.toString();
      final session = MovieBoxSession.fromToken(token, uid);
      _cachedSession = session;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefTokenKey, session.token);
      if (session.userId != null) await prefs.setString(_prefUserIdKey, session.userId!);
      if (session.expiresAt != null) await prefs.setInt(_prefExpKey, session.expiresAt!);
      await prefs.setInt(_prefCreatedKey, session.createdAt);

      debugPrint('[MovieBox] visitor-login success, got token');
      return session.token;
    } catch (e) {
      debugPrint('[MovieBox] fetch session error: $e');
      return null;
    } finally {
      client.close();
    }
  }

  void invalidate() {
    _cachedSession = null;
    SharedPreferences.getInstance().then((p) {
      p.remove(_prefTokenKey);
      p.remove(_prefUserIdKey);
      p.remove(_prefExpKey);
      p.remove(_prefCreatedKey);
    });
  }
}
