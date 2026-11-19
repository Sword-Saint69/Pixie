import 'package:material_ui/material_ui.dart';

/// Shared visual language taken from the inspo folder: editorial cards,
/// oversized figures, micro-labels, status segments and dot matrices.

Color successColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF4ADE80)
    : const Color(0xFF16A34A);

Color warningColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFFBBF24)
    : const Color(0xFFD97706);

Color dangerColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFF87171)
    : const Color(0xFFDC2626);

class PixieCard extends StatelessWidget {
  const PixieCard({super.key, required this.child, this.padding = 20});

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.035), blurRadius: 18, offset: const Offset(0, 4)),
        ],
      ),
      padding: EdgeInsets.all(padding),
      child: child,
    );
  }
}

class MicroLabel extends StatelessWidget {
  const MicroLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        letterSpacing: 1.3,
        fontWeight: FontWeight.w700,
        color: color ?? cs.onSurfaceVariant,
      ),
    );
  }
}

class AnimatedNumberText extends StatelessWidget {
  const AnimatedNumberText(this.value, {super.key, this.style});

  final int value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<int>(
        tween: IntTween(begin: 0, end: value),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOut,
        builder: (context, animated, _) => Text('$animated', style: style),
      );
}

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.hint,
    this.count,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? hint;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: PixieCard(
        padding: 14,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const Spacer(),
                if (hint != null)
                  Text(hint!, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 14),
            count != null
                ? AnimatedNumberText(count!,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: cs.onSurface, height: 1))
                : Text(value,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: cs.onSurface, height: 1)),
            const SizedBox(height: 5),
            Text(label, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Three-part bar in the style of the "Workflow health" reference: one
/// continuous track split proportionally between success, skipped and failed.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.done, required this.skipped, required this.failed});

  final int done;
  final int skipped;
  final int failed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = done + skipped + failed;
    final segments = <(int, Color)>[
      (done, successColor(context)),
      (skipped, warningColor(context)),
      (failed, dangerColor(context)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 14,
            child: Row(
              children: [
                for (final (count, color) in segments)
                  if (count > 0)
                    Expanded(
                      flex: count,
                      child: Container(color: color),
                    ),
                if (total == 0) Expanded(child: Container(color: cs.surfaceContainerHighest)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _legend('Uploaded', done, total, successColor(context), cs),
            _legend('Skipped', skipped, total, warningColor(context), cs),
            _legend('Failed', failed, total, dangerColor(context), cs),
          ],
        ),
      ],
    );
  }

  Widget _legend(String label, int count, int total, Color color, ColorScheme cs) => Expanded(
        child: Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                total == 0 ? label : '$label ${(count / total * 100).round()}%',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

/// Dot matrix from the "athletic score" / heatmap references. Each dot is a
/// file from the current session, coloured by its outcome.
class DotMatrix extends StatelessWidget {
  const DotMatrix({super.key, required this.states});

  /// 0 = pending, 1 = uploaded, 2 = skipped, 3 = failed.
  final List<int> states;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (states.isEmpty) {
      return Text('No files in this session yet.', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final state in states)
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: switch (state) {
                1 => successColor(context),
                2 => warningColor(context),
                3 => dangerColor(context),
                _ => cs.surfaceContainerHighest,
              },
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

/// Pill row used as a settings/activity switcher in the references.
class PillSwitch<T> extends StatelessWidget {
  const PillSwitch({
    super.key,
    required this.values,
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final List<String> labels;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < values.length; i++)
            GestureDetector(
              onTap: () => onChanged(values[i]),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: selected == values[i] ? cs.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: selected == values[i]
                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6)]
                      : null,
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected == values[i] ? FontWeight.w700 : FontWeight.w500,
                    color: selected == values[i] ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
