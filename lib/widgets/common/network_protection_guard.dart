import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../config/app_theme.dart';

class NetworkProtectionGuard extends StatefulWidget {
  const NetworkProtectionGuard({
    super.key,
    required this.child,
  });

  final Widget child;

  /// Fast and reliable check for actual internet connectivity
  static Future<bool> checkInternet() async {
    try {
      final socket = await Socket.connect(
        '1.1.1.1',
        53,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } catch (_) {}

    try {
      final socket = await Socket.connect(
        '8.8.8.8',
        53,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } catch (_) {}

    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 2));
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        return true;
      }
    } catch (_) {}

    return false;
  }

  @override
  State<NetworkProtectionGuard> createState() => _NetworkProtectionGuardState();
}

class _NetworkProtectionGuardState extends State<NetworkProtectionGuard>
    with WidgetsBindingObserver {
  bool _isChecking = true;
  bool _hasInternet = true;
  int _countdown = 5;
  Timer? _countdownTimer;
  Timer? _periodicCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _performCheck();
    // Periodic background check every 15 seconds to guard against mid-session dropouts
    _periodicCheckTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _performCheck(isPeriodic: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _periodicCheckTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _performCheck();
    }
  }

  Future<void> _performCheck({bool isPeriodic = false}) async {
    final connected = await NetworkProtectionGuard.checkInternet();
    if (!mounted) return;

    if (!connected) {
      if (_hasInternet) {
        setState(() {
          _hasInternet = false;
          _isChecking = false;
          _countdown = 5;
        });
        _startCountdownAndExit();
      }
    } else {
      if (!_hasInternet || _isChecking) {
        _countdownTimer?.cancel();
        setState(() {
          _hasInternet = true;
          _isChecking = false;
        });
      }
    }
  }

  void _startCountdownAndExit() {
    _countdownTimer?.cancel();
    _countdown = 5;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        _forceExit();
      } else {
        setState(() {
          _countdown--;
        });
      }
    });
  }

  void _forceExit() {
    _countdownTimer?.cancel();
    SystemNavigator.pop();
    Future.delayed(const Duration(milliseconds: 250), () {
      exit(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasInternet) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          _forceExit();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Warning Icon with red container
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.5),
                          width: 2,
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          LucideIcons.wifiOff,
                          size: 46,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Branded app logo + title
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/images/app_logo.png',
                          width: 28,
                          height: 28,
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox.shrink(),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'MOVIE HOME',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    const Text(
                      'No Internet Connection',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),

                    Text(
                      'Movie Home requires an active internet connection to load media and streams.\n'
                      'Please connect to Wi-Fi or mobile data and reopen the app.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Auto-exit countdown badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Exiting app in $_countdown seconds...',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Force exit button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _forceExit,
                        icon: const Icon(LucideIcons.logOut, size: 20),
                        label: const Text(
                          'Exit App Now',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Retry button
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _isChecking = true);
                        _performCheck();
                      },
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('Check Again'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
