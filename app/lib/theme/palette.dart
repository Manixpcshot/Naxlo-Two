import 'package:flutter/material.dart';

/// Naxlo Two's own identity: deep violet + signal cyan on near-black.
///
/// Chosen to be visibly distinct from Happ's blue/green palette while keeping
/// the same "one accent, calm surfaces" logic. Health states use a
/// non-colour-only encoding (icon + shape) because red/green colour-blind users
/// are exactly the population running a privacy tool for hours at a time.
abstract final class Palette {
  static const Color violet = Color(0xFF7C4DFF);
  static const Color violetDim = Color(0xFF5A36C9);
  static const Color cyan = Color(0xFF22D3EE);
  static const Color amber = Color(0xFFF5A524);
  static const Color rose = Color(0xFFF04463);
  static const Color mint = Color(0xFF2FBF71);

  /// Surfaces, dark → lightest.
  static const Color ink0 = Color(0xFF0A0A0F);
  static const Color ink1 = Color(0xFF12121A);
  static const Color ink2 = Color(0xFF1A1B26);
  static const Color ink3 = Color(0xFF242634);
  static const Color mist = Color(0xFFEDEEF6);
  static const Color mutedInk = Color(0xFF9A9CB0);

  /// Light theme surfaces.
  static const Color paper = Color(0xFFFBFBFE);
  static const Color paperRaised = Color(0xFFF2F2F8);
  static const Color inkOnPaper = Color(0xFF16161D);

  static const Color scoreTrack = Color(0x1FFFFFFF);
  static const Color hairline = Color(0x22FFFFFF);

  /// Latency band colours, matched to the thresholds used by the ranker so the
  /// badge and the score never disagree with each other.
  static Color latency(double ms) {
    if (ms < 0) return mutedInk;
    if (ms < 80) return mint;
    if (ms < 180) return cyan;
    if (ms < 400) return amber;
    return rose;
  }

  static IconData latencyIcon(double ms) {
    if (ms < 0) return Icons.help_outline_rounded;
    if (ms < 80) return Icons.bolt_rounded;
    if (ms < 180) return Icons.speed_rounded;
    if (ms < 400) return Icons.timelapse_rounded;
    return Icons.warning_amber_rounded;
  }
}
