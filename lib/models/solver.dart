import 'schedule.dart';

/// 简化的排班求解器 - 暴力搜索所有可能排列
class SimpleScheduleSolver {
  final List<String> names;
  final List<int> userRestDays; // 每人指定的休班日(0=周日...6=周六)
  final int closingDay; // 关门日(0=周日...6=周六)
  final String? lastSunday99999; // 上周日盯99999的人(跨周约束)

  SimpleScheduleSolver({
    required this.names,
    required this.userRestDays,
    this.closingDay = 6,
    this.lastSunday99999,
  });

  /// 完全求解排班表（休班日+角色分配），offset可获取不同组合
  WeekSchedule? solve(DateTime weekStart, {int offset = 0}) {
    // 6个工作日(排除关门日)
    final workingDays = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != closingDay) workingDays.add(d);
    }

    if (workingDays.length != 6) {
      throw Exception('工作日数量不对: ${workingDays.length}');
    }

    // 尝试所有可能的排班
    final solutions = <WeekSchedule>[];
    _backtrack(0, workingDays, <DaySchedule>[], solutions, weekStart);

    if (solutions.isEmpty) return null;
    return solutions[offset % solutions.length];
  }

  /// 仅求解角色分配（休班日已固定），用于刷新按钮
  WeekSchedule? solveRolesOnly(DateTime weekStart,
      List<int> restPeoplePerDay, {int offset = 0}) {
    final workingDays = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != closingDay) workingDays.add(d);
    }

    final solutions = <WeekSchedule>[];
    _backtrackRolesOnly(
        0, workingDays, restPeoplePerDay, <DaySchedule>[], solutions,
        weekStart);

    if (solutions.isEmpty) return null;
    return solutions[offset % solutions.length];
  }

  void _backtrack(
    int idx,
    List<int> workingDays,
    List<DaySchedule> current,
    List<WeekSchedule> solutions,
    DateTime weekStart,
  ) {
    if (idx >= workingDays.length) {
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
    // 遍历所有 (99999, 协管, 休息) 排列
    for (final p99999 in names) {
      for (final pXieguan in names) {
        if (pXieguan == p99999) continue;
        final pRest = names.firstWhere((n) => n != p99999 && n != pXieguan);

        current.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: p99999,
          personXieguan: pXieguan,
          personRest: pRest,
        ));

        _backtrack(idx + 1, workingDays, current, solutions, weekStart);
        current.removeLast();
        if (solutions.isNotEmpty) return;
      }
    }
  }

  /// 休班日固定版：仅回溯 99999/协管分配
  void _backtrackRolesOnly(
    int idx,
    List<int> workingDays,
    List<int> restPeoplePerDay,
    List<DaySchedule> current,
    List<WeekSchedule> solutions,
    DateTime weekStart,
  ) {
    if (idx >= workingDays.length) {
      final valid = _validateRolesOnly(current, workingDays);
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
    final restName = names[restPeoplePerDay[idx]];
    final workers = <String>[];
    for (final n in names) {
      if (n != restName) workers.add(n);
    }

    // 2种分配：worker[0]=99999, worker[1]=协管 或 反过来
    for (int i = 0; i < 2; i++) {
      current.add(DaySchedule(
        dayIndex: dayIndex,
        person99999: workers[i],
        personXieguan: workers[1 - i],
        personRest: restName,
      ));
      _backtrackRolesOnly(
          idx + 1, workingDays, restPeoplePerDay, current, solutions,
          weekStart);
      current.removeLast();
      if (solutions.isNotEmpty) return;
    }
  }

  /// 角色分配验证（含休班日约束完整版）
  bool _validate(List<DaySchedule> schedule, List<int> workingDays) {
    // 统计每人各项天数
    final count99999 = <String, int>{for (var n in names) n: 0};
    final countXieguan = <String, int>{for (var n in names) n: 0};
    final countRest = <String, int>{for (var n in names) n: 0};

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
        if (workingDays[i + 1] - workingDays[i] == 1) {
          return false;
        }
      }
    }

    // 5. 用户指定的休班日必须满足
    for (int i = 0; i < names.length; i++) {
      final name = names[i];
      final specifiedRestDay = userRestDays[i];
      bool foundRest = false;
      for (final day in schedule) {
        if (day.dayIndex == specifiedRestDay && day.personRest == name) {
          foundRest = true;
          break;
        }
      }
      if (!foundRest) return false;
    }

    // 6. 跨周约束：上周日盯99999的人，周一(dayIndex=0)不能盯99999
    if (lastSunday99999 != null) {
      for (final day in schedule) {
        if (day.dayIndex == 0 && day.person99999 == lastSunday99999) {
          return false;
        }
      }
    }

    return true;
  }

  /// 休班天数固定版验证：仅检查 99999/协管约束
  bool _validateRolesOnly(
      List<DaySchedule> schedule, List<int> workingDays) {
    final count99999 = <String, int>{for (var n in names) n: 0};
    final countXieguan = <String, int>{for (var n in names) n: 0};

    for (final day in schedule) {
      count99999[day.person99999] = count99999[day.person99999]! + 1;
      countXieguan[day.personXieguan] = countXieguan[day.personXieguan]! + 1;
    }

    // 每人恰好2天99999
    for (final name in names) {
      if (count99999[name] != 2) return false;
    }
    // 每人恰好2天协管
    for (final name in names) {
      if (countXieguan[name] != 2) return false;
    }

    // 同人99999不能连续
    for (int i = 0; i < schedule.length - 1; i++) {
      if (schedule[i].person99999 == schedule[i + 1].person99999) {
        if (workingDays[i + 1] - workingDays[i] == 1) {
          return false;
        }
      }
    }

    // 跨周约束：上周日盯99999的人，周一(dayIndex=0)不能盯99999
    if (lastSunday99999 != null) {
      for (final day in schedule) {
        if (day.dayIndex == 0 && day.person99999 == lastSunday99999) {
          return false;
        }
      }
    }

    return true;
  }
}
