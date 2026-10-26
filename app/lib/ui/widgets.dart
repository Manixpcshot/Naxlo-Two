import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:naxlo_core/naxlo_core.dart';

import 'package:naxlo_two/l10n/strings.dart';
import 'package:naxlo_two/theme/palette.dart';
import 'package:naxlo_two/ui/motion.dart';

/// Shared UI vocabulary: the surfaces, chips and meters every page is built
/// from, and the only place motion is decided for them.
///
/// Pages deliberately do not hand-roll cards or chips. It is what lets this
/// file change how the whole app moves — a ranked row, a latency pill and the
/// settings panels all settle on the same curve — without six files drifting
/// into six slightly different animations.
class Section extends StatelessWidget {
  const Section({required this.title, this.subtitle, required this.child, this.trailing, super.key});

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 9),
            child: Row(
              children: <Widget>[
                // The accent tick, not a coloured label: a heading that is also a
                // button would look clickable, and half these sections have their
                // own trailing control already.
                Container(
                  width: 3,
                  height: 15,
                  decoration: BoxDecoration(
                    gradient: Palette.accentGradient,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
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
          FadeSlideIn(offset: const Offset(0, 10), duration: Motion.base, child: child),
        ],
      ),
    );
  }
}

/// The app's card. Hover lifts it and lights its edge; tapping sinks it.
///
/// `Ink` rather than `Material` so the splash is drawn over the gradient instead
/// of under it — with `Material` the ripple disappears the moment a decoration
/// is added, which is how most Flutter apps end up with dead buttons.
class Panel extends StatefulWidget {
  const Panel({
    this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.selected = false,
    this.tint,
    super.key,
  });

  final Widget? child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  /// Draws the lit edge: used by rows that mean "this is the one in use".
  final bool selected;

  /// Optional accent for the wash. Left null the panel stays neutral, because a
  /// green-tinted card for "connected" and a green-tinted card for "healthy but
  /// idle" would make the colour mean nothing.
  final Color? tint;

  @override
  State<Panel> createState() => _PanelState();
}

class _PanelState extends State<Panel> {
  bool _hover = false;

  bool get _interactive => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final Color tint = widget.tint ?? (widget.selected ? theme.colorScheme.primary : Palette.glass(dark));
    final double edge = widget.selected ? 0.44 : (_hover && _interactive ? 0.30 : (dark ? 0.10 : 0.16));

    return MouseRegion(
      cursor: _interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: _interactive ? (PointerEnterEvent _) => setState(() => _hover = true) : null,
      onExit: _interactive ? (PointerExitEvent _) => setState(() => _hover = false) : null,
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Palette.radius),
            color: dark ? Palette.ink2 : Palette.paperRaised,
            border: Border.all(color: tint.withOpacity(edge), width: 1),
            boxShadow: <BoxShadow>[
              if (dark)
                BoxShadow(
                  color: Colors.black.withOpacity(_hover && _interactive ? 0.44 : 0.30),
                  blurRadius: _hover && _interactive ? 26 : 14,
                  offset: Offset(0, _hover && _interactive ? 10 : 5),
                )
              else
                BoxShadow(
                  color: Colors.black.withOpacity(_hover && _interactive ? 0.10 : 0.05),
                  blurRadius: _hover && _interactive ? 18 : 10,
                  offset: Offset(0, _hover && _interactive ? 7 : 3),
                ),
            ],
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                tint.withOpacity(dark ? 0.10 : 0.30),
                Colors.transparent,
              ],
            ),
          ),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(Palette.radius),
            hoverColor: Colors.transparent,
            splashColor: tint.withOpacity(0.16),
            highlightColor: tint.withOpacity(0.08),
            child: _HoverLift(
              lifted: _hover && _interactive,
              child: Padding(
                padding: widget.padding,
                child: widget.child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lifts the contents a hair on hover, without moving the border.
///
/// Separate from the card because transforming both drags the hairline with it,
/// and the whole point of the state is that the frame gets lighter while the
/// surface moves.
class _HoverLift extends StatelessWidget {
  const _HoverLift({required this.lifted, required this.child});

  final bool lifted;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return child;
    return AnimatedContainer(
      duration: Motion.time(context, Motion.quick),
      curve: Motion.enter,
      transform: Matrix4.translationValues(0, lifted ? -0.6 : 0, 0),
      child: child,
    );
  }
}

class KvRow extends StatelessWidget {
  const KvRow({required this.key_, required this.value, this.hint, this.emphasise = false, super.key});

  final String key_;
  final String value;
  final String? hint;

  /// For values that are the reason the row exists (bytes, throughput) — they
  /// count up instead of snapping.
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
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
            child: SwapText(
              text: value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: emphasise ? FontWeight.w700 : FontWeight.w600,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (hint != null && hint!.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ),
        ],
      ),
    );
  }
}

/// Score bar: a 0..1 score as a gradient bar plus a percentage.
///
/// The bar is the part people actually read while scanning 60 rows, so the
/// number sits small next to it rather than being the only signal. It animates
/// its own width and never its position, because a ranking row that slides while
/// it re-scores makes the list impossible to re-read.
class ScoreBar extends StatelessWidget {
  const ScoreBar({
    required this.score,
    this.height = 6,
    this.color,
    this.showValue = true,
    this.gradient = false,
    super.key,
  });

  final double score;
  final double height;
  final Color? color;
  final bool showValue;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double fraction = score.clamp(0.0, 1.0).toDouble();
    final Color fill = color ?? theme.colorScheme.primary;
    return Row(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth.isFinite ? constraints.maxWidth : 120;
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: fraction),
                duration: Motion.time(context, Motion.base),
                curve: Motion.enter,
                builder: (BuildContext context, double value, Widget? _) {
                  return Stack(
                    children: <Widget>[
                      Container(
                        height: height,
                        decoration: BoxDecoration(
                          color: Palette.scoreTrack,
                          borderRadius: BorderRadius.circular(height / 2),
                        ),
                      ),
                      SizedBox(
                        height: height,
                        width: (width * value).clamp(0.0, width),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(height / 2),
                            gradient: gradient
                                ? LinearGradient(
                                    colors: <Color>[fill.withOpacity(0.55), fill],
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                  )
                                : null,
                            color: gradient ? null : fill,
                            boxShadow: <BoxShadow>[
                              BoxShadow(color: fill.withOpacity(0.45), blurRadius: height * 1.8, spreadRadius: -1),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        if (showValue)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: SwapText(
              text: (fraction * 100).toStringAsFixed(0),
              style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

class LatencyChip extends StatelessWidget {
  const LatencyChip({required this.latencyMs, this.jitterMs, this.dense = false, this.animate = true, super.key});

  final int latencyMs;
  final int? jitterMs;
  final bool dense;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color colour = Palette.latency(latencyMs.toDouble());
    final String label = latencyMs < 0
        ? NaxloLocalizations.of(context).t('label.noData')
        : '$latencyMs${NaxloLocalizations.of(context).t('unit.ms')}';
    final TextStyle? style = theme.textTheme.labelSmall?.copyWith(
      color: colour,
      fontWeight: FontWeight.w700,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return TweenAnimationBuilder<Color?>(
      // Colour tweens between latency bands instead of snapping, so a node that
      // has just become "slow" is a movement the eye can follow down the list.
      tween: ColorTween(end: colour),
      duration: Motion.time(context, animate ? Motion.base : Duration.zero),
      curve: Motion.enter,
      builder: (BuildContext context, Color? value, Widget? child) {
        final Color c = value ?? colour;
        return Container(
          padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 3.5),
          decoration: BoxDecoration(
            color: c.withOpacity(0.14),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: c.withOpacity(0.34)),
          ),
          child: child,
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Palette.latencyIcon(latencyMs.toDouble()), size: dense ? 12 : 14, color: colour),
          const SizedBox(width: 4),
          SwapText(
            text: jitterMs != null && jitterMs! > 0 ? '$label ±$jitterMs' : label,
            style: style,
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
    // Icon + colour, never colour alone — a red/green colour-blind user running
    // this tool for hours is the majority of the audience, not the edge case.
    final (IconData icon, Color colour) = switch (state) {
      HealthState.healthy => (Icons.check_circle_rounded, Palette.mint),
      HealthState.degraded => (Icons.error_outline_rounded, Palette.amber),
      HealthState.down => (Icons.cancel_rounded, Palette.rose),
      HealthState.unknown => (Icons.help_outline_rounded, Palette.mutedInk),
    };
    return AnimatedSwitcher(
      duration: Motion.time(context, Motion.quick),
      switchInCurve: Motion.press,
      transitionBuilder: (Widget child, Animation<double> animation) => ScaleTransition(
        scale: Tween<double>(begin: 0.72, end: 1).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: Icon(icon, key: ValueKey<HealthState>(state), size: 16, color: colour),
    );
  }
}

class RankBadge extends StatelessWidget {
  const RankBadge({required this.rank, this.isCurrent = false, super.key});

  final int rank;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;
    return AnimatedContainer(
      duration: Motion.time(context, Motion.base),
      curve: Motion.enter,
      width: 27,
      height: 27,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: isCurrent ? Palette.accentGradient : null,
        color: isCurrent ? null : theme.colorScheme.surface.withOpacity(0.55),
        border: Border.all(color: isCurrent ? Colors.transparent : Palette.hairline),
        boxShadow: <BoxShadow>[
          if (isCurrent) BoxShadow(color: accent.withOpacity(0.40), blurRadius: 14, spreadRadius: -3),
        ],
      ),
      child: AnimatedSwitcher(
        duration: Motion.time(context, Motion.quick),
        child: Text(
          '$rank',
          key: ValueKey<int>(rank),
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: isCurrent ? Colors.white : null,
          ),
        ),
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
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FadeSlideIn(
              offset: const Offset(0, 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: <Color>[
                      theme.colorScheme.primary.withOpacity(0.16),
                      theme.colorScheme.secondary.withOpacity(0.07),
                    ],
                  ),
                ),
                child: Icon(icon, size: 26, color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 18),
              FadeSlideIn(delay: const Duration(milliseconds: 90), offset: const Offset(0, 8), child: action!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Weight slider with the live normalised share beside the label, so a user sees
/// what "0.9" actually does to the ranking instead of guessing.
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
    final ThemeData theme = Theme.of(context);
    final double share = totalWeight <= 0 ? 0 : (value / totalWeight).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              // The share is a bar as well as a number: comparing six of these
              // vertically is the actual question ("does latency dominate?"), and
              // six percentages make that a reading task.
              SizedBox(
                width: 46,
                child: ScoreBar(score: share, height: 3, showValue: false, gradient: true),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 34,
                child: SwapText(
                  text: '${(share * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
