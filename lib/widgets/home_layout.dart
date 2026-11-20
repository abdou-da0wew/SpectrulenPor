import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Responsive composition for the Home screen.
///
/// The Scaffold owns the app bar. This widget owns the remaining system insets
/// exactly once and keeps the camera and primary capture action reachable.
class HomeLayout extends StatelessWidget {
  const HomeLayout({
    super.key,
    required this.statusBar,
    required this.sourceToggle,
    required this.camera,
    required this.captureAction,
    required this.analysisFooter,
    this.hazardBanner,
    this.connectionStatus,
    this.glassesSetup,
    this.spectrum,
  });

  final Widget statusBar;
  final Widget sourceToggle;
  final Widget camera;
  final Widget captureAction;
  final Widget analysisFooter;
  final Widget? hazardBanner;
  final Widget? connectionStatus;
  final Widget? glassesSetup;
  final Widget? spectrum;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final isWide = size.width >= 900 ||
              (size.width >= 720 && size.width > size.height * 1.12);
          if (isWide) return _buildWide(constraints);
          if (size.height < 620) return _buildCompact(constraints);
          return _buildRegular();
        },
      ),
    );
  }

  Widget _buildRegular() {
    return Column(
      key: const ValueKey('home-regular-layout'),
      children: [
        statusBar,
        if (hazardBanner != null) hazardBanner!,
        sourceToggle,
        if (connectionStatus != null) connectionStatus!,
        if (glassesSetup != null) glassesSetup!,
        Expanded(child: camera),
        captureAction,
        if (spectrum != null) spectrum!,
        analysisFooter,
      ],
    );
  }

  Widget _buildCompact(BoxConstraints constraints) {
    final headerHeight = math.min(
      constraints.maxHeight,
      math.max(88.0, math.min(148.0, constraints.maxHeight * 0.30)),
    );

    return Column(
      key: const ValueKey('home-compact-layout'),
      children: [
        SizedBox(
          height: headerHeight,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                statusBar,
                if (hazardBanner != null) hazardBanner!,
                sourceToggle,
                if (connectionStatus != null) connectionStatus!,
                if (glassesSetup != null) glassesSetup!,
                if (spectrum != null) spectrum!,
              ],
            ),
          ),
        ),
        Expanded(child: camera),
        captureAction,
        analysisFooter,
      ],
    );
  }

  Widget _buildWide(BoxConstraints constraints) {
    final panelWidth = (constraints.maxWidth * 0.32).clamp(260.0, 360.0);

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        key: const ValueKey('home-wide-layout'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(child: camera),
                const SizedBox(height: 8),
                captureAction,
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: panelWidth,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  statusBar,
                  if (hazardBanner != null) hazardBanner!,
                  sourceToggle,
                  if (connectionStatus != null) connectionStatus!,
                  if (glassesSetup != null) glassesSetup!,
                  if (spectrum != null) spectrum!,
                  analysisFooter,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
