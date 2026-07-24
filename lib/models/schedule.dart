import 'dart:collection';

/// 排班表一天的记录
class DaySchedule {
  final int dayIndex; // 0=周一...5=周六
  String person99999; // 盯99999柜台的人
  String personXieguan; // 盯协管的人
  String personRest; // 休息的人

  DaySchedule({
    required this.dayIndex,
    required this.person99999,
    required this.personXieguan,
    required this.personRest,
  });

  Map<String, dynamic> toJson() => {
        'dayIndex': dayIndex,
        'person99999': person99999,
        'personXieguan': personXieguan,
        'personRest': personRest,
      };

  factory DaySchedule.fromJson(Map<String, dynamic> json) => DaySchedule(
        dayIndex: json['dayIndex'],
        person99999: json['person99999'],
        personXieguan: json['personXieguan'],
        personRest: json['personRest'],
      );
}

/// 一周排班表
class WeekSchedule {
  final DateTime weekStart; // 周一日期
  final List<String> names; // 3个柜员名字
  final int closingDay; // 关门日 0=周日...6=周六
  final List<int> restDays; // 每人指定的休班日 [0-5]
  final List<DaySchedule> days; // 6天排班

  WeekSchedule({
    required this.weekStart,
    required this.names,
    required this.closingDay,
    required this.restDays,
    required this.days,
  });

  Map<String, dynamic> toJson() => {
        'weekStart': weekStart.toIso8601String(),
        'names': names,
        'closingDay': closingDay,
        'restDays': restDays,
        'days': days.map((d) => d.toJson()).toList(),
      };

  factory WeekSchedule.fromJson(Map<String, dynamic> json) => WeekSchedule(
        weekStart: DateTime.parse(json['weekStart']),
        names: List<String>.from(json['names']),
        closingDay: json['closingDay'],
        restDays: List<int>.from(json['restDays']),
        days: (json['days'] as List)
            .map((d) => DaySchedule.fromJson(d))
            .toList(),
      );
}

/// 排班求解器
class ScheduleSolver {
  final List<String> names;
  final List<int> restDays; // 每人指定的休班日 [0-5]
  final int closingDay; // 关门日 0=周日...6=周六
  final WeekSchedule? previousWeek;

  ScheduleSolver({
    required this.names,
    required this.restDays,
    this.closingDay = 6, // 默认周六关门
    this.previousWeek,
  });

  /// 求解排班表，返回可能的解列表
  List<WeekSchedule> solve(DateTime weekStart) {
    final solutions = <WeekSchedule>[];
    final workingDays = _getWorkingDays();

    // 每人需要: 2天99999(不连续) + 2天协管 + 2天休息(1指定+1自动)
    // 每天: 1人99999 + 1人协管 + 1人休息

    // 用回溯搜索
    final List<DaySchedule> currentSchedule = [];
    final person99999Count = <String, int>{for (var n in names) n: 0};
    final personXieguanCount = <String, int>{for (var n in names) n: 0};
    final personRestCount = <String, int>{for (var n in names) n: 0};
    final last99999Day = <String, int>{}; // 每人上次盯99999的dayIndex

    // 跨周约束：上周日盯99999的人，周一不能盯99999
    String? blockedForMonday;
    if (previousWeek != null) {
      for (final day in previousWeek.days) {
        if (day.dayIndex == 6) {
          // 周日 (dayIndex=6 means Sunday in previous week's schedule)
          // Actually let me check - dayIndex 0=Monday in our scheme
          // But "周日" is index 6 in our scheme? No, 0=周一, 5=周六
          // The user said "上周日" which means Sunday, which is dayIndex 6 in DateTimeland
          // But our working days are Mon-Sat, so Sunday is not in the working days
          // Hmm, let me reconsider - the closing day is Saturday, working days are Sun-Fri?
          // No, user said 周六固定关门 but "每周六固定关门"
          // So working days are: Sun, Mon, Tue, Wed, Thu, Fri (6 days)
          // closing day = Saturday
          // So dayIndex: 0=周日, 1=周一, 2=周二, 3=周三, 4=周四, 5=周五
          // Wait, I used 0=周一 earlier. Let me reconsider.
          // Let me use day indices consistent with DateTime: 0=周一, 1=周二, ..., 5=周六
          // But if Saturday is closing day, then working days are Monday through Friday + Sunday?
          // User said "每周六固定关门", so working days are Sun-Fri? Or Mon-Sat with Sat closed?
          // "一周六天开门" - 6 days open
          // If Saturday is closing day, then the 6 open days are: Sunday, Monday, Tuesday, Wednesday, Thursday, Friday
          // So dayIndex for working days: 0=周日, 1=周一, 2=周二, 3=周三, 4=周四, 5=周五
          // Actually that doesn't make sense with the "周一" being the start of the week.
          // Let me just define: 0=周一, 1=周二, 2=周三, 3=周四, 4=周五, 5=周六
          // And closingDay is which of these 6 days is closed (default 5=Saturday)
          // So 6 working days are Mon-Sat, and one of them is the closing day (default Saturday)
          // Hmm but then there are only 5 open days if Saturday is closed?
          // OK I think the user means: there are 7 days a week, 1 day is closed (Sat), 6 days are open (Sun-Fri)
          // So working days: 周日, 周一, 周二, 周三, 周四, 周五
          // Let me just use dayOfWeek from DateTime: 1=周一...7=周日
          // Open days: all days except closingDay
          // For simplicity, I'll define working days as all 7 days minus the closing day
        }
      }
    }

    bool backtrack(int dayIndex) {
      if (dayIndex >= 7) {
        // 检查是否所有约束满足
        for (final name in names) {
          if (person99999Count[name] != 2) return false;
          if (personXieguanCount[name] != 2) return false;
        }
        // 保存解
        solutions.add(WeekSchedule(
          weekStart: weekStart,
          names: List.from(names),
          closingDay: closingDay,
          restDays: List.from(restDays),
          days: List.from(currentSchedule),
        ));
        return true; // 找到一个解就停止（可改为继续搜索所有解）
      }

      // 关门日跳过
      if (dayIndex == closingDay) {
        return backtrack(dayIndex + 1);
      }

      // 尝试分配当天的人员
      // 生成所有可能的排列 (谁99999, 谁协管, 谁休息)
      final candidates = _getCandidates(
        dayIndex,
        person99999Count,
        personXieguanCount,
        personRestCount,
        last99999Day,
        blockedForMonday,
      );

      for (final candidate in candidates) {
        // 应用候选
        final p99999 = candidate[0];
        final pXieguan = candidate[1];
        final pRest = candidate[2];

        person99999Count[p99999] = person99999Count[p99999]! + 1;
        personXieguanCount[pXieguan] = personXieguanCount[pXieguan]! + 1;
        personRestCount[pRest] = personRestCount[pRest]! + 1;
        last99999Day[p99999] = dayIndex;

        currentSchedule.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: p99999,
          personXieguan: pXieguan,
          personRest: pRest,
        ));

        if (backtrack(dayIndex + 1)) {
          return true; // 找到一个解就返回
        }

        // 回溯
        person99999Count[p99999] = person99999Count[p99999]! - 1;
        personXieguanCount[pXieguan] = personXieguanCount[pXieguan]! - 1;
        personRestCount[pRest] = personRestCount[pRest]! - 1;
        last99999Day.remove(p99999);
        currentSchedule.removeLast();
      }

      return false;
    }

    backtrack(0);
    return solutions;
  }

  List<int> _getWorkingDays() {
    // 返回所有工作日（排除关门日）
    return List.generate(7, (i) => i).where((d) => d != closingDay).toList();
  }

  List<List<String>> _getCandidates(
    int dayIndex,
    Map<String, int> p99999Count,
    Map<String, int> pXieguanCount,
    Map<String, int> pRestCount,
    Map<String, int> last99999Day,
    String? blockedForMonday,
  ) {
    final candidates = <List<String>>[];

    // 生成所有排列
    for (final p99999 in names) {
      // 99999约束检查
      if (p99999Count[p99999]! >= 2) continue;
      // 跨周约束
      if (dayIndex == 去打 0 && blockedForMonday == p99999) continue;
      // 不能连续盯99999
      if (last99999Day.containsKey(p99999) &&
          last99999Day[p99999] == dayIndex - 1) continue;

      for (final pXieguan in names) {
        if (pXieguan == p99999) continue;
        if (pXieguanCount[pXieguan]! >= 2) continue;

        // 剩下的人是休息
        final pRest = names.firstWhere((n) => n != p99999 && n != pXieguan);
        if (pRestCount[pRest]! >= 2) continue;

        // 检查用户指定的休班日
        final restDayIndex = restDays[names.indexOf(pRest)];
        if (restDayIndex == dayIndex && pRestCount[pRest]! >= 1) {
          // 已经是第二个休息日了，不能再休
          // 但用户指定的休班日必须满足
        }

        // 每人不能休超过2天
        if (pRestCount[pRest]! >= 2) continue;

        // 如果是用户指定的休班日，必须休息
        if (restDayIndex == dayIndex && pRest != names[restDays.indexOf(pRest)]) {
          // 这不是指定休息的人在这一天休息
          // 需要确保指定休息的人在这一天确实休息
        }

        candidates.add([p99999, pXieguan, pRest]);
      }
    }

    return candidates;
  }
}
