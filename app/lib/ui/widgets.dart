import 'package:flutter/material.dart';
import 'package:naxlo_core/naxlo_core.dart';

import 'package:naxlo_two/l10n/strings.dart';
import 'package:naxlo_two/theme/palette.dart';

/// Small shared UI pieces. Kept in one file because every page uses a few of
/// them and a folder of 6-line widget files makes the diff noise worse than the
/// reuse is worth.

class Section extends StatelessWidget {
  const Section({required this.title, this.subtitle, required this.child, this.trailing, super.key});

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({required this.child, this.padding = const EdgeInsets.all(14), this.onTap, super.key});

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class KvRow extends StatelessWidget {
  const KvRow({required this.key_, required this.value, this.hint, super.key});

  final String key_;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Text(key_, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ),
        ],
      ),
    );
  }
}

/// Score bar: a 0..1 score as a bar plus a percentage.
///
/// The bar is the part people actually read while scanning 60 rows, so the
/// number is rendered small next to it rather than being the only signal.
class ScoreBar extends StatelessWidget {
  const ScoreBar({required this.score, this.height = 6, this.color, this.showValue = true, super.key});

  final double score;
  final double height;
  final Color? color;
  final bool showValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = score.clamp(0.0, 1.0).toDouble();
    return Row(
      children: <Widget>[
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(height / 2),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: fraction),
              duration: const Duration(milliseconds: 320),
              builder: (BuildContext context, double value, Widget? _) {
                return LinearProgressIndicator(
                  value: value,
                  minHeight: height,
                  backgroundColor: Palette.scoreTrack,
                  valueColor: AlwaysStoppedAnimation<Color>(color ?? theme.colorScheme.primary),
                );
              },
            ),
          ),
        ),
        if (showValue)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: Text(
              // No surrounding `'${…}'`: the value is already a String, and the
              // interpolation was only making the lint complain.
              (fraction * 100).toStringAsFixed(0),
              style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

class LatencyChip extends StatelessWidget {
  const LatencyChip({required this.latencyMs, this.jitterMs, this.dense = false, super.key});

  final int latencyMs;
  final int? jitterMs;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = Palette.latency(latencyMs.toDouble());
    final label = latencyMs < 0
        ? NaxloLocalizations.of(context).t('label.noData')
        : '$latencyMs${NaxloLocalizations.of(context).t('unit.ms')}';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 2 : 3),
      decoration: BoxDecoration(
        color: colour.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Palette.latencyIcon(latencyMs.toDouble()), size: dense ? 12 : 14, color: colour),
          const SizedBox(width: 4),
          Text(
            jitterMs != null && jitterMs! > 0 ? '$label ±$jitterMs' : label,
            style: theme.textTheme.labelSmall?.copyWith(color: colour, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class HealthIcon extends StatelessWidget {
  const HealthIcon({required this.state, super.key});

  final HealthState state;

  @override
  Widget build(BuildContext context) {
    // Icon + colour, never colour alone.
    switch (state) {
      case HealthState.healthy:
        return const Icon(Icons.check_circle_rounded, size: 16, color: Palette.mint);
      case HealthState.degraded:
        return const Icon(Icons.error_outline_rounded, size: 16, color: Palette.amber);
      case HealthState.down:
        return const Icon(Icons.cancel_rounded, size: 16, color: Palette.rose);
      case HealthState.unknown:
        return const Icon(Icons.help_outline_rounded, size: 16, color: Palette.mutedInk);
    }
  }
}

class RankBadge extends StatelessWidget {
  const RankBadge({required this.rank, this.isCurrent = false, super.key});

  final int rank;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isCurrent
            ? theme.colorScheme.primary.withOpacity(0.22)
            : theme.colorScheme.surface.withOpacity(0.6),
        border: Border.all(
          color: isCurrent ? theme.colorScheme.primary : Palette.hairline,
        ),
      ),
      child: Text(
        '$rank',
        style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.title, this.action, this.icon = Icons.inbox_rounded, super.key});

  final String title;
  final Widget? action;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (action != null) ...<Widget>[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Weight slider with the live normalised share shown next to the label, so a
/// user can see what "0.9" actually does to the ranking instead of guessing.
class WeightSlider extends StatelessWidget {
  const WeightSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.totalWeight,
    super.key,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double totalWeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = totalWeight <= 0 ? 0.0 : (value / totalWeight);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(
                '${(share * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 8),
              Text(value.toStringAsFixed(2), style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ],
          ),
          Slider(
            value: value.clamp(0.0, 1.0),
            max: 1.0,
            divisions: 20,
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
