import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../domain/dashboard.dart';

// Chart rules (dataviz): thin marks, 2px surface gaps between fills, 2px
// lines, ≥8px markers, recessive grid, one value axis, legends for ≥2 series,
// text in text tokens (never series colours), touch tooltips with exact values.

const _tooltipBg = AppColors.elevated;
const _axisText = TextStyle(color: AppColors.textMuted, fontSize: 11);
const _chartAnimation = Duration(milliseconds: 150);

/// Expense breakdown: top categories as a thin donut, the rest folded into
/// "Other". The legend doubles as a value table (category, amount, share).
class ExpenseDonut extends StatefulWidget {
  const ExpenseDonut({super.key, required this.breakdown});

  final List<CategoryTotal> breakdown;

  @override
  State<ExpenseDonut> createState() => _ExpenseDonutState();
}

class _DonutSlice {
  const _DonutSlice(this.label, this.paise, this.color);

  final String label;
  final int paise;
  final Color color;
}

class _ExpenseDonutState extends State<ExpenseDonut> {
  int? _touched;

  List<_DonutSlice> get _slices {
    final sorted = [...widget.breakdown]
      ..sort((a, b) => b.totalPaise.compareTo(a.totalPaise));
    const max = 5; // == AppColors.chartCategorical.length
    final slices = <_DonutSlice>[
      for (final (i, c) in sorted.take(max).indexed)
        _DonutSlice(c.category, c.totalPaise, AppColors.chartCategorical[i]),
    ];
    if (sorted.length > max) {
      final rest = sorted.skip(max).fold<int>(0, (s, c) => s + c.totalPaise);
      slices.add(_DonutSlice('Other', rest, AppColors.chartOther));
    }
    return slices;
  }

  @override
  Widget build(BuildContext context) {
    final slices = _slices;
    final total = slices.fold<int>(0, (s, c) => s + c.paise);
    final textTheme = Theme.of(context).textTheme;
    final touched = _touched;
    final centerLabel = touched != null && touched < slices.length
        ? slices[touched]
        : null;

    return Column(
      children: [
        SizedBox(
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 62,
                  startDegreeOffset: -90,
                  pieTouchData: PieTouchData(
                    touchCallback: (event, response) {
                      final index =
                          response?.touchedSection?.touchedSectionIndex;
                      setState(
                        () => _touched =
                            event.isInterestedForInteractions &&
                                index != null &&
                                index >= 0
                            ? index
                            : null,
                      );
                    },
                  ),
                  sections: [
                    for (final (i, s) in slices.indexed)
                      PieChartSectionData(
                        value: s.paise.toDouble(),
                        color: s.color,
                        radius: i == touched ? 24 : 18,
                        showTitle: false,
                      ),
                  ],
                ),
                duration: _chartAnimation,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    centerLabel?.label ?? 'Total spent',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Money.compact(centerLabel?.paise ?? total),
                    style: textTheme.titleLarge,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final s in slices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: s.color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    s.label,
                    style: textTheme.bodyLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(Money.format(s.paise), style: textTheme.bodyLarge),
                SizedBox(
                  width: 48,
                  child: Text(
                    total == 0 ? '' : '${(s.paise * 100 / total).round()}%',
                    style: textTheme.bodySmall,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Income vs expense per month (grouped bars, one money axis).
class IncomeExpenseBars extends StatelessWidget {
  const IncomeExpenseBars({super.key, required this.trend});

  final List<MonthSummary> trend;

  @override
  Widget build(BuildContext context) {
    final maxPaise = trend.fold<int>(
      0,
      (m, s) => math.max(m, math.max(s.incomePaise, s.expensePaise)),
    );
    final top = _niceCeil(maxPaise);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Legend(
          items: [
            ('Income', AppColors.chartIncome),
            ('Expense', AppColors.chartExpense),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 180,
          child: BarChart(
            BarChartData(
              maxY: top.toDouble(),
              minY: 0,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: top / 4,
                getDrawingHorizontalLine: (_) =>
                    const FlLine(color: AppColors.chartGrid, strokeWidth: 1),
              ),
              titlesData: _titles(
                left: (v) => Money.compact(v.round()),
                bottom: (i) => i >= 0 && i < trend.length
                    ? DateFormat('MMM').format(trend[i].month)
                    : '',
                interval: top / 4,
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => _tooltipBg,
                  getTooltipItem: (group, _, rod, rodIndex) => BarTooltipItem(
                    '${DateFormat('MMM yyyy').format(trend[group.x].month)}\n'
                    '${rodIndex == 0 ? 'Income' : 'Expense'} '
                    '${Money.format(rod.toY.round())}',
                    const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  ),
                ),
              ),
              barGroups: [
                for (final (i, s) in trend.indexed)
                  BarChartGroupData(
                    x: i,
                    barsSpace: 2,
                    barRods: [
                      _rod(s.incomePaise, AppColors.chartIncome),
                      _rod(s.expensePaise, AppColors.chartExpense),
                    ],
                  ),
              ],
            ),
            duration: _chartAnimation,
          ),
        ),
      ],
    );
  }

  BarChartRodData _rod(int paise, Color color) => BarChartRodData(
    toY: paise.toDouble(),
    color: color,
    width: 10,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
  );
}

/// Closing balance at the end of each month (single series, no legend).
class BalanceTrendLine extends StatelessWidget {
  const BalanceTrendLine({super.key, required this.trend});

  final List<MonthSummary> trend;

  @override
  Widget build(BuildContext context) {
    final values = [for (final s in trend) s.closingPaise];
    final maxV = values.fold<int>(0, math.max);
    final minV = values.fold<int>(0, math.min);
    final top = _niceCeil(maxV);
    final bottom = minV < 0 ? -_niceCeil(-minV) : 0;
    final interval = math.max(1, (top - bottom) / 4).toDouble();
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: bottom.toDouble(),
          maxY: top.toDouble(),
          minX: 0,
          maxX: (trend.length - 1).toDouble(),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: interval,
            getDrawingHorizontalLine: (v) => FlLine(
              color: v == 0 ? AppColors.border : AppColors.chartGrid,
              strokeWidth: 1,
            ),
          ),
          titlesData: _titles(
            left: (v) => Money.compact(v.round()),
            bottom: (i) => i >= 0 && i < trend.length
                ? DateFormat('MMM').format(trend[i].month)
                : '',
            interval: interval,
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => _tooltipBg,
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  LineTooltipItem(
                    '${DateFormat('MMM yyyy').format(trend[spot.x.round()].month)}\n'
                    'Closing ${Money.format(spot.y.round())}',
                    const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (final (i, v) in values.indexed)
                  FlSpot(i.toDouble(), v.toDouble()),
              ],
              color: AppColors.chartBalance,
              barWidth: 2,
              isCurved: false,
              dotData: FlDotData(
                getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                  radius: 4,
                  color: AppColors.chartBalance,
                  strokeWidth: 2,
                  strokeColor: AppColors.surface,
                ),
              ),
            ),
          ],
        ),
        duration: _chartAnimation,
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.items});

  final List<(String, Color)> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.lg,
      children: [
        for (final (label, color) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
      ],
    );
  }
}

FlTitlesData _titles({
  required String Function(double value) left,
  required String Function(int index) bottom,
  required double interval,
}) => FlTitlesData(
  topTitles: const AxisTitles(),
  rightTitles: const AxisTitles(),
  leftTitles: AxisTitles(
    sideTitles: SideTitles(
      showTitles: true,
      reservedSize: 52,
      interval: interval,
      getTitlesWidget: (value, meta) => SideTitleWidget(
        meta: meta,
        child: Text(left(value), style: _axisText),
      ),
    ),
  ),
  bottomTitles: AxisTitles(
    sideTitles: SideTitles(
      showTitles: true,
      reservedSize: 24,
      interval: 1,
      getTitlesWidget: (value, meta) => SideTitleWidget(
        meta: meta,
        child: Text(bottom(value.round()), style: _axisText),
      ),
    ),
  ),
);

/// Rounds up to a "nice" axis maximum (1, 2, 2.5, 5 × 10ⁿ), never 0.
int _niceCeil(int paise) {
  if (paise <= 0) return 100000; // ₹1,000 so an empty chart still has a scale
  final exponent = (math.log(paise) / math.ln10).floor();
  final base = math.pow(10, exponent).toInt();
  for (final step in [1, 2, 2.5, 5, 10]) {
    final candidate = (base * step).round();
    if (candidate >= paise) return candidate;
  }
  return base * 10;
}
