import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../net/branding.dart';
import '../net/connectivity.dart';

const String _bundledLogo = 'assets/branding/qaat_logo.png';

final Map<String, Uint8List> _logoBytesCache = {};

/// Decoded bytes of a `data:` base64 image, memoised per URL — or null.
Uint8List? _dataUrlBytes(String url) {
  if (!url.startsWith('data:')) return null;
  try {
    return _logoBytesCache.putIfAbsent(
      url,
      () => base64Decode(url.substring(url.indexOf(',') + 1)),
    );
  } catch (_) {
    return null;
  }
}

/// The institution logo: the tenant's `logoUrl` when it is a base64 data image, else
/// the bundled mark. Renders in a 6dp-radius tile, exactly like the native app.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.branding, this.size = 32});

  final Branding? branding;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bmp = _dataUrlBytes(branding?.logoUrl ?? '');
    if (bmp != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          bmp,
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _bundled(size),
        ),
      );
    }
    return _bundled(size);
  }

  Widget _bundled(double size) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: Image.asset(
      _bundledLogo,
      width: size,
      height: size,
      fit: BoxFit.contain,
    ),
  );
}

/// The app bar's identity: the institution logo, then "KIU QAAT", then the institution
/// name. ONE header for every role — a long tenant name wraps to two lines whole rather
/// than being cut off mid-word. [compact] drops the secondary line for busy bars.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key, this.branding, this.compact = false});

  final Branding? branding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        BrandLogo(branding: branding, size: 30),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'KIU QAAT',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  height: 1.13,
                ),
              ),
              if (!compact && (branding?.name.isNotEmpty ?? false))
                Text(
                  branding!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, height: 1.2),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A faint, centered institution-logo watermark for every screen. Plain image with no
/// gesture handler, so touches pass straight through. Place it last in a full-screen
/// Stack so it overlays all content. Uses the tenant's own mark when the branding
/// supplies one; otherwise the bundled KIU QAAT mark — a watermark is not optional.
class BrandWatermark extends StatelessWidget {
  const BrandWatermark({super.key, this.branding});

  final Branding? branding;

  @override
  Widget build(BuildContext context) {
    final bmp = _dataUrlBytes(branding?.logoUrl ?? '');
    final marker = bmp != null
        ? Image.memory(
            bmp,
            width: MediaQuery.sizeOf(context).width * 0.6,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          )
        : Image.asset(
            _bundledLogo,
            width: MediaQuery.sizeOf(context).width * 0.6,
            fit: BoxFit.contain,
          );
    return IgnorePointer(
      child: Center(child: Opacity(opacity: 0.05, child: marker)),
    );
  }
}

/// The slim strip above the tab content: shown only while [netStatus] is offline,
/// so an "everything saved, will sync" promise is visible to the person who decided
/// to keep recording in a lift. Auto-dismisses the moment the probe lands again.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<NetStatus>(
      valueListenable: netStatus,
      builder: (context, status, _) {
        if (status != NetStatus.offline) return const SizedBox.shrink();
        final fg = theme.colorScheme.onErrorContainer;
        return Material(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.cloud_off, size: 16, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Offline — everything you record is saved on this phone and '
                    'will sync automatically.',
                    style: theme.textTheme.bodySmall?.copyWith(color: fg),
                  ),
                ),
                TextButton(
                  onPressed: NetMonitor.probe,
                  child: const Text('Check again'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
