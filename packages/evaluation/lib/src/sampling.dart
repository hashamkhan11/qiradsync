import 'dart:math';

/// An inclusive `[min, max]` range, read straight from [WorkloadConfig] so
/// every sampled amount has a one-line reason attached to its range, not
/// buried in generator code.
class IntRange {
  const IntRange(this.min, this.max)
    : assert(min <= max, 'IntRange min must not exceed max');

  final int min;
  final int max;

  Map<String, int> toJson() => {'min': min, 'max': max};
}

/// A uniform integer in [range], inclusive.
int uniformInt(Random random, IntRange range) {
  if (range.min == range.max) return range.min;
  return range.min + random.nextInt(range.max - range.min + 1);
}

/// A log-uniform integer in [range] (spec: amounts), so a small business's
/// ordinary small entries are common and a rare large one does not drag the
/// sample's mean toward itself the way a uniform draw would.
int logUniformInt(Random random, IntRange range) {
  if (range.min <= 0 || range.max <= range.min) return range.min;
  final logMin = log(range.min);
  final logMax = log(range.max);
  final value = exp(logMin + random.nextDouble() * (logMax - logMin));
  return value.round().clamp(range.min, range.max);
}

/// An inclusive `[min, max]` range of fractions (0..1), for example "withdraw
/// 10% to 50% of the settled share."
class DoubleRange {
  const DoubleRange(this.min, this.max)
    : assert(min <= max, 'DoubleRange min must not exceed max');

  final double min;
  final double max;

  Map<String, double> toJson() => {'min': min, 'max': max};
}

/// A uniform double in [range], inclusive of [DoubleRange.min].
double uniformDouble(Random random, DoubleRange range) =>
    range.min + random.nextDouble() * (range.max - range.min);

/// True with probability [p] (0..1).
bool bernoulli(Random random, double p) => random.nextDouble() < p;

/// The chance of at least one event in one hour, for a Poisson process whose
/// expected count per day is [perDay]. Used to turn a daily rate into an
/// hourly coin flip without tracking a running Poisson count.
double hourlyChanceFromDailyRate(double perDay) => 1 - exp(-perDay / 24);
