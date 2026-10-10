import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

class MovieBoxCrypto {
  MovieBoxCrypto._();

  static const List<int> defaultSecretBytes = [
    0xef, 0xa8, 0x91, 0x97, 0x4e, 0xec, 0xd3, 0x14,
    0x8d, 0xf6, 0x3a, 0xa6, 0x11, 0x60, 0x2d, 0xef,
    0xd1, 0x01, 0x25, 0x9b, 0xa5, 0x21, 0x02, 0x2c,
    0x57, 0xae, 0x05, 0x66, 0xbd, 0x8e,
  ];

  static const int signatureBodyMaxBytes = 102400;

  static String md5Hex(List<int> bytes) {
    return md5.convert(bytes).toString();
  }

  static String generateXClientToken(int ts) {
    final tsStr = ts.toString();
    final reversedTs = tsStr.split('').reversed.join('');
    final hashVal = md5Hex(utf8.encode(reversedTs));
    return '$tsStr,$hashVal';
  }

  static String sortedQueryString(String urlStr) {
    final uri = Uri.tryParse(urlStr);
    if (uri == null || uri.queryParametersAll.isEmpty) return '';
    final sortedKeys = uri.queryParametersAll.keys.toList()..sort();
    final parts = <String>[];
    for (final key in sortedKeys) {
      for (final val in uri.queryParametersAll[key]!) {
        parts.add('$key=$val');
      }
    }
    return parts.join('&');
  }

  static String buildCanonicalString(
    String method,
    String? accept,
    String? contentType,
    String urlStr,
    String? body,
    int timestampMs,
  ) {
    final uri = Uri.tryParse(urlStr);
    String canonicalUrl = urlStr;
    if (uri != null) {
      final path = uri.path;
      final query = sortedQueryString(urlStr);
      canonicalUrl = query.isEmpty ? path : '$path?$query';
    }

    String bodyHash = '';
    String bodyLength = '';
    if (body != null) {
      final bytes = utf8.encode(body);
      final len = bytes.length;
      final truncated = len > signatureBodyMaxBytes
          ? bytes.sublist(0, signatureBodyMaxBytes)
          : bytes;
      bodyHash = md5Hex(truncated);
      bodyLength = len.toString();
    }

    return '${method.toUpperCase()}\n'
        '${accept ?? ""}\n'
        '${contentType ?? ""}\n'
        '$bodyLength\n'
        '$timestampMs\n'
        '$bodyHash\n'
        '$canonicalUrl';
  }

  static String generateXTrSignature(
    String method,
    String? accept,
    String? contentType,
    String urlStr,
    String? body,
    int timestampMs,
  ) {
    final canonical = buildCanonicalString(
      method,
      accept,
      contentType,
      urlStr,
      body,
      timestampMs,
    );
    final hmac = Hmac(md5, defaultSecretBytes);
    final digest = hmac.convert(utf8.encode(canonical));
    final sigB64 = base64Encode(digest.bytes);
    return '$timestampMs|2|$sigB64';
  }

  static (String, String) generateClientInfoAndUa() {
    final rng = Random();
    final androidVersions = [
      ('11', 'RP1A.200720.011'),
      ('12', 'S1B.220414.015'),
      ('13', 'TQ2A.230405.003'),
    ];
    final redmiDevices = [
      ('2201117TY', 'Redmi'),
      ('22101316G', 'Redmi'),
      ('23078RKD5C', 'Redmi'),
    ];
    final versionCodes = [50020119, 50020120, 50020121];
    final android = androidVersions[rng.nextInt(androidVersions.length)];
    final device = redmiDevices[rng.nextInt(redmiDevices.length)];
    final versionCode = versionCodes[rng.nextInt(versionCodes.length)];

    String randomHex(int len) {
      return List.generate(len, (_) => rng.nextInt(16).toRadixString(16)).join();
    }

    final deviceId = randomHex(32);
    final gaid =
        '${randomHex(8)}-${randomHex(4)}-${randomHex(4)}-${randomHex(4)}-${randomHex(12)}';

    final userAgent =
        'com.community.oneroom/$versionCode (Linux; U; Android ${android.$1}; en_US; ${device.$1}; Build/${android.$2}; Cronet/135.0.7012.3)';

    final clientInfo = jsonEncode({
      'package_name': 'com.community.oneroom',
      'version_name': '4.0.01.0813.03',
      'version_code': versionCode,
      'os': 'android',
      'os_version': android.$1,
      'install_ch': 'ps',
      'device_id': deviceId,
      'install_store': 'ps',
      'gaid': gaid,
      'brand': device.$2,
      'model': device.$1,
      'system_language': 'en',
      'net': 'NETWORK_WIFI',
      'region': 'SG',
      'timezone': 'Asia/Singapore',
      'sp_code': '40401',
      'X-Play-Mode': '2',
    });

    return (userAgent, clientInfo);
  }

  static String randomSpoofedIp() {
    final rng = Random();
    final prefixes = [
      '103.28.248',
      '118.189.50',
      '128.199.100',
      '175.136.10',
      '115.164.20',
      '5.195.10',
      '178.238.10',
      '103.241.226',
      '49.36.12',
      '117.195.45',
    ];
    final prefix = prefixes[rng.nextInt(prefixes.length)];
    final c = rng.nextInt(253) + 1;
    return '$prefix.$c';
  }

  static Map<String, String> buildSignedHeaders({
    required String method,
    required String url,
    String? body,
    String? authToken,
    required String userAgent,
    required String clientInfo,
    required String spoofedIp,
  }) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    const accept = 'application/json';
    const contentType = 'application/json';

    final clientToken = generateXClientToken(ts);
    final signature = generateXTrSignature(
      method,
      accept,
      contentType,
      url,
      body,
      ts,
    );

    final headers = <String, String>{
      'User-Agent': userAgent,
      'Accept': accept,
      'Content-Type': contentType,
      'Connection': 'keep-alive',
      'x-client-token': clientToken,
      'x-tr-signature': signature,
      'x-client-info': clientInfo,
      'x-client-status': '0',
      'x-forwarded-for': spoofedIp,
    };

    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    return headers;
  }
}
