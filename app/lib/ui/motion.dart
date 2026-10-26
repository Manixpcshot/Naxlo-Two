import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Motion vocabulary for Naxlo Two.
///
/// The one rule this file exists to enforce: **everything settles**. The widget
/// tests drive the tree with `pumpAndSettle()`, and a controller that repeats
/// forever makes that hang until the test times out — so "add some life to the
/// UI" done naively does not look pretty, it looks like the suite froze. Every
/// looping effect here is therefore gated on a state the tests never reach (a
/// running engine, a busy probe), and stops the instant that state ends.
/// Everything else is a one-shot entrance or an implicit animation from the
/// previous value to the next, which is also the honest behaviour: a card that
/// keeps breathing while nothing is happening teaches the user to ignore it.
abstract final class Motion {
  static const Duration micro = Duration(milliseconds: 110);
  static const Duration quick = Duration(milliseconds: 200);
  static const Duration base = Duration(milliseconds: 340);
  static const Duration slow = Duration(milliseconds: 560);

  /// Fast out, long settle. Overshoot is deliberately limited to press feedback:
  /// in a dense ranked table it reads as wobble, and rows appear to still be
  /// moving after they have settled.
  static const Curve enter = Curves.easeOutCubic;
  static const Curve leave = Curves.easeInCubic;
  static const Curve press = Curves.easeOutBack;

  /// Cascade step between siblings, so a page assembles instead of appearing.
  static const Duration step = Duration(milliseconds: 42);

  /// Honours the OS "reduce motion" setting. These degrade to a still frame
  /// rather than to a quicker version of the same movement: for the vestibular
  /// case a 60ms slide is still a slide.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration time(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;

  /// Delay for the `index`-th child of a list. Clamped because past a dozen rows
  /// the entrance stops being a cascade and becomes a loading spinner: the last
  /// item of a 60-row ranking would otherwise land 2.5 seconds after the first.
  static Duration cascade(int index, {Duration step = Motion.step, Duration lead = Duration.zero}) {
    return lead + step * index.clamp(0, 12);
  }
}

/// One-shot entrance: fade plus a short translate.
///
/// Pass `tag` to replay the entrance when the value behind the row changes — a
/// re-sorted ranking slides, an unrelated parent rebuild does not. Without it the
/// alternative is a `State` per row just to hold a key.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 14),
    this.duration = Motion.base,
    this.curve = Motion.enter,
    this.tag,
    super.key,
  });

  final Widget child;
  final Duration delay;
  final Offset offset;
  final Duration duration;
  final Curve curve;
  final Object? tag;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return child;
    final int totalUs = duration.inMicroseconds + delay.inMicroseconds;
    return TweenAnimationBuilder<double>(
      key: tag == null ? null : ValueKey<Object>('fade-$tag'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(microseconds: totalUs),
      // The delay is folded in by hand instead of using `curve:` on the builder,
      // because a curve applied to the whole span bends the flat waiting part too
      // — which is what makes staggered children look late rather than arriving.
      builder: (BuildContext context, double t, Widget? child) {
        final double raw = totalUs <= 0
            ? 1
            : ((t * totalUs - delay.inMicroseconds) / math.max(1, duration.inMicroseconds))
                .clamp(0.0, 1.0)
                .toDouble();
        final double p = curve.transform(raw);
        return Opacity(
          opacity: p,
          child: Transform.translate(
            offset: Offset(offset.dx * (1 - p), offset.dy * (1 - p)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Cross-fade with a directional bias, for content that changes inside a frame
/// that stays: a latency number, a status word, a rank.
class SwapText extends StatelessWidget {
  const SwapText({
    required this.text,
    this.style,
    this.maxLines = 1,
    this.axis = Axis.vertical,
    super.key,
  });

  final String text;
  final TextStyle? style;
  final int maxLines;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final Duration dur = Motion.time(context, Motion.quick);
    if (dur == Duration.zero) return _label();
    return AnimatedSwitcher(
      duration: dur,
      switchInCurve: Motion.enter,
      switchOutCurve: Motion.leave,
      transitionBuilder: (Widget child, Animation<double> animation) {
        final Offset from = axis == Axis.vertical ? const Offset(0, 0.34) : const Offset(-0.34, 0);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: from, end: Offset.zero).animate(animation),
            child: child,
          ),
        );
      },
      // The default layout builder clips, and this sits inside rows of chips where
      // a descender is already at the edge of its box.
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        clipBehavior: Clip.none,
        children: <Widget>[...previous, if (current != null) current],
      ),
      child: _label(),
    );
  }

  Widget _label() {
    return Text(
      text,
      key: ValueKey<String>(text),
      style: style,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Press and hover feedback: a sink on tap, a breath on hover, an optional glow.
/// Implicit animations only, so a settled tree has no ticker and no state beyond
/// two booleans.
class PressScale extends StatefulWidget {
  const PressScale({
    required this.child,
    this.onTap,
    this.pressedScale = 0.964,
    this.hoverScale = 1.012,
    this.glow,
    this.borderRadius = 18,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final double hoverScale;
  final Color? glow;
  final double borderRadius;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final Color? glow = widget.glow;
    final bool reduced = Motion.reduced(context);
    final double scale = _down ? widget.pressedScale : (_hover && !reduced ? widget.hoverScale : 1);
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (PointerEnterEvent _) => setState(() => _hover = true),
      onExit: (PointerExitEvent _) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (TapDownDetails _) => setState(() => _down = true),
        onTapCancel: widget.onTap == null ? null : () => setState(() => _down = false),
        onTapUp: widget.onTap == null ? null : (TapUpDetails _) => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: Motion.time(context, Motion.quick),
          curve: Motion.press,
          child: AnimatedContainer(
            duration: Motion.time(context, Motion.base),
            curve: Motion.enter,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              boxShadow: _hover && glow != null
                  ? <BoxShadow>[BoxShadow(color: glow!.withOpacity(0.28), blurRadius: 26, spreadRadius: -6)]
                  : const <BoxShadow>[],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Ambient breathing, for things that are genuinely alive right now.
///
/// `active` is not decorative. Pass it a state that is false when nothing is
/// happening — and false in every test — because a ticking controller that never
/// stops is exactly what `pumpAndSettle` waits for forever. With `active` false
/// the builder runs once with `t = 0` and no ticker exists at all.
class LivePulse extends StatefulWidget {
  const LivePulse({
    required this.active,
    required this.builder,
    this.period = const Duration(milliseconds: 1500),
    super.key,
  });

  final bool active;
  final Widget Function(BuildContext context, double t) builder;
  final Duration period;

  @override
  State<LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<LivePulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.period);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(LivePulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.period != widget.period) {
      _controller.duration = widget.period;
      _sync();
    }
  }

  void _sync() {
    if (widget.active) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
    if (!_controller.isAnimating && _controller.value != 0) _controller.value = 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || Motion.reduced(context)) return widget.builder(context, 0);
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        // Cosine rather than the raw ramp: at t=0 and t=1 the frames are identical,
        // so the loop has no visible seam. A linear or triangle ramp both blink.
        final double t = 0.5 - 0.5 * math.cos(2 * math.pi * _controller.value);
        return widget.builder(context, t);
      },
    );
  }
}

/// A lit card: gradient wash, and — only while something is running — a highlight
/// that drifts across it.
///
/// The drift rides on [LivePulse] rather than its own controller so that a
/// disconnected app has no animation at all, and a test tree has none either.
class AuroraTint extends StatelessWidget {
  const AuroraTint({
    required this.colors,
    required this.child,
    this.active = false,
    this.borderRadius = 18,
    super.key,
  });

  final List<Color> colors;
  final Widget child;
  final bool active;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: LivePulse(
        active: active,
        builder: (BuildContext context, double t) {
          final double shift = (t - 0.5) * 0.22;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(shift, -shift),
                radius: 1.3,
                colors: <Color>[
                  Colors.white.withOpacity(0.030 + 0.055 * t),
                  Colors.transparent,
                ],
              ),
            ),
            child: child,
          );
        },
      ),
    );
  }
}
