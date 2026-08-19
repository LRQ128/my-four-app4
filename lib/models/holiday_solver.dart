import 'holiday_schedule.dart';

/// 角色约束（刷新时手动指定某天的角色）
/// forceRest: null=自动分配；''=该天无人休班（3人在岗）；人名=指定该人休班
/// force99999 / forceXieguan: 指定盯岗角色（可空=自动）
class RoleConstraint {
  final String? forceRest;
  final String? force99999;
  final String? forceXieguan;

  const RoleConstraint({this.forceRest, this.force99999, this.forceXieguan});

  bool get isEmpty => forceRest == null && force99999 == null && forceXieguan == null;
}

/// 求解结果：排班 + 可行性 + 推理过程
class HolidayPlanResult {
  final HolidaySchedule? schedule;
  final bool feasible;
  final List<String> messages;

  const HolidayPlanResult(this.schedule, this.feasible, this.messages);
}

/// ============================================================
/// 假期长排班求解器
///
/// 核心模型（N 名柜员，每天保证至少 2 人担岗）：
///  - 关门日：全员休班
///  - 开门日：1 人休班（其余担岗），或无人休班（3 人在岗，2 人担岗 1 人轮空）
///  - 每人休假总天数 = targetRestDays
///
/// 推导：设关门 C 天、开门/工作日 O 天
///  - 每人关门日已休 C 天，还需休 R = targetRestDays - C 天
///  - 每天开门日可提供 1 个补休名额，共需 N×R 个名额
///  - 要求 O ≥ N×R 才可行
///  - 补休名额优先分配在假期内开门日，不足则扩散到假期前后工作日
///
/// 支持手动指定休班人（forceRest）时，自动对未指定日做"再平衡"，
/// 保证最终每人休假总数仍等于 targetRestDays。
/// ============================================================
class HolidayScheduleSolver {
  final List<String> names;
  final int targetRestDays;
  final Set<int> closedDayKeys; // yyyyMMdd
  final DateTime coverStart;
  final DateTime coverEnd;
  final String? prevSunday99999;

  HolidayScheduleSolver({
    required this.names,
    required this.targetRestDays,
    required this.closedDayKeys,
    required this.coverStart,
    required this.coverEnd,
    this.prevSunday99999,
  });

  static (DateTime, DateTime) computeCover(DateTime hStart, DateTime hEnd) {
    final s = DateKey.dateOnly(hStart);
    final e = DateKey.dateOnly(hEnd);
    final monday = s.subtract(Duration(days: s.weekday - 1));
    final sunday = e.add(Duration(days: 7 - e.weekday));
    return (monday, sunday);
  }

  List<DateTime> _allDates() {
    final dates = <DateTime>[];
    var cur = DateKey.dateOnly(coverStart);
    final end = DateKey.dateOnly(coverEnd);
    while (!cur.isAfter(end)) {
      dates.add(cur);
      cur = cur.add(const Duration(days: 1));
    }
    return dates;
  }

  HolidayPlanResult solve({
    required String name,
    required DateTime holidayStart,
    required DateTime holidayEnd,
    Map<int, RoleConstraint>? constraints,
  }) {
    final messages = <String>[];
    final allDates = _allDates();
    final hs = DateKey.key(holidayStart);
    final he = DateKey.key(holidayEnd);
    final cs = constraints ?? const <int, RoleConstraint>{};

    final closed = allDates
        .where((d) => closedDayKeys.contains(DateKey.key(d)))
        .toList();
    final opening = allDates
        .where((d) => !closedDayKeys.contains(DateKey.key(d)))
        .toList();
    final C = closed.length;
    final O = opening.length;
    final T = targetRestDays;

    messages.add('本次覆盖 ${allDates.length} 天，其中关门 $C 天、开门/上班 $O 天。假期${holidayStart.month}/${holidayStart.day}-${holidayEnd.month}/${holidayEnd.day}。');

    if (T < C) {
      messages.add('❌ 每人休假天数($T) 小于关门天数($C)。关门日已全员休班 $C 天，休假天数必须 ≥ 关门天数。');
      return HolidayPlanResult(null, false, messages);
    }

    final R = T - C;
    final needed = names.length * R;
    messages.add('每人关门日已休 $C 天，还需休 $R 天；${names.length} 人共需 $needed 个补休名额。');

    if (needed > O) {
      messages.add('❌ 开门/上班日仅 $O 天，最多提供 $O 个补休名额，不足以满足 $needed 个。请减少每人休假天数，或把更多日设为开门上班日。');
      return HolidayPlanResult(null, false, messages);
    }

    // ---- 确定每天休班人 ----
    // 1) 优先用用户手动指定（forceRest）
    // 2) 未指定（free）的开门日：做再平衡，保证每人总数=T
    final freeDays = <DateTime>[];
    final forcedRest = <int, String>{}; // dateKey -> 休班人（'' 表示无人休）
    for (final d in opening) {
      final k = DateKey.key(d);
      final con = cs[k];
      if (con != null && con.forceRest != null) {
        forcedRest[k] = con.forceRest!;
      } else {
        freeDays.add(d);
      }
    }

    // 再平衡：满足每人总数=T
    //  已指定(forceRest)的天不参与自动分配；未指定(freeDays)中选一部分分配休班人
    final forcedCount = <String, int>{for (var n in names) n: 0};
    for (final rn in forcedRest.values) {
      if (rn.isNotEmpty) forcedCount[rn] = forcedCount[rn]! + 1;
    }
    // 每人还需在 freeDays 中休的次数
    final need = <String, int>{};
    var totalNeed = 0;
    var infeasible = false;
    for (final n in names) {
      final nR = R - forcedCount[n]!;
      need[n] = nR;
      if (nR < 0) infeasible = true;
      totalNeed += nR;
    }
    if (infeasible) {
      messages.add('❌ 手动指定的休班使某人休假天数超过 $T 天，请减少其指定休班。');
      return HolidayPlanResult(null, false, messages);
    }
    if (totalNeed > freeDays.length) {
      messages.add('❌ 未指定休班的开门日(${freeDays.length} 天)不足以完成补休，'
          '请减少每人休假天数或放宽休班指定。');
      return HolidayPlanResult(null, false, messages);
    }

    // 未指定日中，优先在假期内开门日分配补休
    bool inHoliday(DateTime d) {
      final k = DateKey.key(d);
      return k >= hs && k <= he;
    }
    freeDays.sort((a, b) {
      final ka = inHoliday(a) ? 0 : 1;
      final kb = inHoliday(b) ? 0 : 1;
      if (ka != kb) return ka - kb;
      return a.compareTo(b);
    });

    // 贪心：前 totalNeed 个 freeDay，每天选"剩余需求最大"的人休班
    final restAssign = <int, String>{};
    for (final f in forcedRest.entries) {
      restAssign[f.key] = f.value;
    }
    var remaining = Map<String, int>.from(need);
    for (var i = 0; i < freeDays.length; i++) {
      final d = freeDays[i];
      if (i >= totalNeed) {
        restAssign[DateKey.key(d)] = ''; // 无人休班，3人在岗
        continue;
      }
      String pick = names[0];
      for (final n in names) {
        if (remaining[n]! > remaining[pick]!) pick = n;
      }
      restAssign[DateKey.key(d)] = pick;
      remaining[pick] = remaining[pick]! - 1;
    }

    // ---- 角色分配（贪心均衡 + 连续性 + 可选指定） ----
    final count99999 = <String, int>{for (var n in names) n: 0};
    final countXieguan = <String, int>{for (var n in names) n: 0};
    String? last99999 = prevSunday99999;

    final days = <HolidayDay>[];
    for (final d in allDates) {
      final k = DateKey.key(d);
      if (closedDayKeys.contains(k)) {
        days.add(HolidayDay(
          date: d, dateKey: k, isClosed: true,
          person99999: '', personXieguan: '', personRest: '',
        ));
        continue;
      }
      final restName = restAssign[k] ?? '';
      final workers = names.where((n) => n != restName).toList();
      final con = cs[k];
      final f9 = con?.force99999;
      final fx = con?.forceXieguan;

      // 约束合法性
      if ((f9 != null && !workers.contains(f9)) ||
          (fx != null && !workers.contains(fx)) ||
          (f9 != null && fx != null && f9 == fx)) {
        messages.add('❌ ${d.month}/${d.day} 的指定角色不可行：某人当天休班或角色冲突。');
        return HolidayPlanResult(null, false, messages);
      }

      String? p99999;
      if (con?.force99999 != null) {
        p99999 = con!.force99999;
      } else {
        final sorted = List<String>.from(workers)
          ..sort((a, b) => count99999[a]!.compareTo(count99999[b]!));
        p99999 = sorted.firstWhere((w) => w != last99999, orElse: () => sorted.first);
      }

      var remaining2 = workers.where((w) => w != p99999).toList();
      String? pXieguan;
      if (con?.forceXieguan != null) {
        pXieguan = con!.forceXieguan;
        if (!remaining2.contains(pXieguan)) {
          messages.add('❌ ${d.month}/${d.day} 协管指定 "$pXieguan" 不可行。');
          return HolidayPlanResult(null, false, messages);
        }
      } else {
        pXieguan = remaining2.reduce((a, b) => countXieguan[a]! <= countXieguan[b]! ? a : b);
      }

      count99999[p99999!] = count99999[p99999]! + 1;
      countXieguan[pXieguan!] = countXieguan[pXieguan]! + 1;
      last99999 = p99999;

      days.add(HolidayDay(
        date: d, dateKey: k, isClosed: false,
        person99999: p99999, personXieguan: pXieguan, personRest: restName,
      ));
    }

    messages.add('✅ 生成完成：每人休假 $T 天，每天至少 2 人在岗。');

    final schedule = HolidaySchedule(
      name: name,
      holidayStart: holidayStart,
      holidayEnd: holidayEnd,
      coverStart: coverStart,
      coverEnd: coverEnd,
      names: List.from(names),
      closedDays: closed.map(DateKey.key).toList(),
      targetRestDays: T,
      days: days,
    );
    return HolidayPlanResult(schedule, true, messages);
  }
}
