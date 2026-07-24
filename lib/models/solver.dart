import 'schedule.dart';

/// 简化的排班求解器 - 暴力搜索所有可能排列
class SimpleScheduleSolver {
  final List<String> names;
  final List<int> userRestDays; // 每人指定的休班日
  final int closingDay; // 关门日(0=周日...6=周六)
  final String? lastSunday99999; // 上周日盯99999的人(跨周约束)

  SimpleScheduleSolver({
    required this.names,
    required this.userRestDays,
    this.closingDay = 6,
    this.lastSunday99999,
  });

  /// 求解排班表
  WeekSchedule? solve(DateTime weekStart) {
    // 6个工作日(排除关门日)
    final workingDays = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != closingDay) workingDays.add(d);
    }

    if (workingDays.length != 6) {
      throw Exception('工作日数量不对: ${workingDays.length}');
    }

    // 每周第一天(周日)的dayIndex是0
    // workingDays[0] = 周日, workingDays[1]=周一, ..., workingDays[5]=周五

    // 尝试所有可能的排班
    final solutions = <WeekSchedule>[];
    _backtrack(0, workingDays, <DaySchedule>[], solutions, weekStart);

    return solutions.isEmpty ? null : solutions.first;
  }

  void _backtrack(
    int idx,
    List<int> workingDays,
    List<DaySchedule> current,
    List<WeekSchedule> solutions,
    DateTime weekStart,
  ) {
    if (idx >= workingDays.length) {
      // 验证完整排班
      final valid = _validate(current, workingDays);
      if (valid) {
        solutions.add(WeekSchedule(
          weekStart: weekStart,
          names: List.from(names),
          closingDay: closingDay,
          restDays: List.from(userRestDays),
          days: List.from(current),
        ));
      }
      return;
    }

    final dayIndex = workingDays[idx];

    // 生成当天所有可能的 (99999, 协管, 休息) 排列
    for (final p99999 in names) {
      for (final pXieguan in names) {
        if (pXieguan == p99999) continue;
        final pRest = names.firstWhere((n) => n != p99999 && n != pXieguan);

        current.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: p99999,
          personXieguan: pXieguan,
          personRest: pRest,
          personNoonRest: p99999, // 盯99999的人中午休息，协管顶替
        ));

        _backtrack(idx + 1, workingDays, current, solutions, weekStart);

        current.removeLast();

        // 找到解就停止
        if (solutions.isNotEmpty) return;
      }
    }
  }

  bool _validate(List<DaySchedule> schedule, List<int> workingDays) {
    // 统计每人各项天数
    final count99999 = <String, int>{for (var n in names) n: 0};
    final countXieguan = <String, int>{for (var n in names) n: 0};
    final countRest = <String, int>{for (var n in names) n: 0};
    final last99999Day = <String, int>{};

    for (final day in schedule) {
      count99999[day.person99999] = count99999[day.person99999]! + 1;
      countXieguan[day.personXieguan] = countXieguan[day.personXieguan]! + 1;
      countRest[day.personRest] = countRest[day.personRest]! + 1;
    }

    // 1. 每人恰好2天99999
    for (final name in names) {
      if (count99999[name] != 2) return false;
    }

    // 2. 每人恰好2天协管
    for (final name in names) {
      if (countXieguan[name] != 2) return false;
    }

    // 3. 每人恰好2天休息（1指定+1自动）
    for (final name in names) {
      if (countRest[name] != 2) return false;
    }

    // 4. 99999不能连续
    for (int i = 0; i < schedule.length - 1; i++) {
      if (schedule[i].person99999 == schedule[i + 1].person99999) {
        // 检查是否连续工作日
        if (workingDays[i + 1] - workingDays[i] == 1) {
          return false;
        }
      }
    }

    // 5. 用户指定的休班日必须满足
    for (int i = 0; i < names.length; i++) {
      final name = names[i];
      final specifiedRestDay = userRestDays[i];
      // 检查该人在指定休班日是否确实休息
      bool foundRest = false;
      for (final day in schedule) {
        if (day.dayIndex == specifiedRestDay && day.personRest == name) {
          foundRest = true;
          break;
        }
      }
      if (!foundRest) return false;
    }

    // 6. 跨周约束：上周日盯99999的人，周一不能盯99999
    if (lastSunday99999 != null) {
      // 周一 = dayIndex 1 (周日=0)
      for (final day in schedule) {
        if (day.dayIndex == 1 && day.person99999 == lastSunday99999) {
          return false;
        }
      }
    }

    return true;
  }
}
