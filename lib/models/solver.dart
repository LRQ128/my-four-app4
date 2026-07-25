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

  /// 完全求解排班表（休班日+角色分配），收集全部解，offset可获取不同完整解
  WeekSchedule? solve(DateTime weekStart, {int offset = 0}) {
    final workingDays = _getWorkingDays();
    if (workingDays.length != 6) {
      throw Exception('工作日数量不对: ${workingDays.length}');
    }
    final solutions = <WeekSchedule>[];
    _backtrack(0, workingDays, <DaySchedule>[], solutions, weekStart);
    if (solutions.isEmpty) return null;
    return solutions[offset % solutions.length];
  }

  /// 获取全部合法完整解的数量
  int countAllSolutions(DateTime weekStart) {
    final workingDays = _getWorkingDays();
    final solutions = <WeekSchedule>[];
    _backtrack(0, workingDays, <DaySchedule>[], solutions, weekStart);
    return solutions.length;
  }

  /// 仅求解角色分配（休班日已固定）—— 收集全部解以支持切换
  /// 返回 [schedule, totalCount]，totalCount 表示一共有多少种合法组合
  MapEntry<WeekSchedule?, int> solveRolesOnlyWithCount(
      DateTime weekStart, List<int> restPeoplePerDay, {int offset = 0}) {
    final workingDays = _getWorkingDays();
    final solutions = <WeekSchedule>[];
    _backtrackRolesOnly(
        0, workingDays, restPeoplePerDay, <DaySchedule>[], solutions,
        weekStart);
    if (solutions.isEmpty) return MapEntry(null, 0);
    return MapEntry(
        solutions[offset % solutions.length], solutions.length);
  }

  List<int> _getWorkingDays() {
    final days = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != closingDay) days.add(d);
    }
    return days;
  }

  void _backtrack(
    int idx,
    List<int> workingDays,
    List<DaySchedule> current,
    List<WeekSchedule> solutions,
    DateTime weekStart,
  ) {
    if (idx >= workingDays.length) {
      if (_validate(current, workingDays)) {
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
      }
    }
  }

  /// 休班日固定版：收集所有合法组合
  void _backtrackRolesOnly(
    int idx,
    List<int> workingDays,
    List<int> restPeoplePerDay,
    List<DaySchedule> current,
    List<WeekSchedule> solutions,
    DateTime weekStart,
  ) {
    if (idx >= workingDays.length) {
      if (_validateRolesOnly(current, workingDays)) {
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
      // 注意：此处不再提前 return，收集全部合法组合
    }
  }

  /// 角色分配验证（含休班日约束完整版）
  bool _validate(List<DaySchedule> schedule, List<int> workingDays) {
    final count99999 = <String, int>{for (var n in names) n: 0};
    final countXieguan = <String, int>{for (var n in names) n: 0};
    final countRest = <String, int>{for (var n in names) n: 0};

    for (final day in schedule) {
      count99999[day.person99999] = count99999[day.person99999]! + 1;
      countXieguan[day.personXieguan] = countXieguan[day.personXieguan]! + 1;
      countRest[day.personRest] = countRest[day.personRest]! + 1;
    }

    for (final name in names) {
      if (count99999[name] != 2) return false;
    }
    for (final name in names) {
      if (countXieguan[name] != 2) return false;
    }
    for (final name in names) {
      if (countRest[name] != 2) return false;
    }

    for (int i = 0; i < schedule.length - 1; i++) {
      if (schedule[i].person99999 == schedule[i + 1].person99999) {
        if (workingDays[i + 1] - workingDays[i] == 1) return false;
      }
    }

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

    if (lastSunday99999 != null) {
      for (final day in schedule) {
        if (day.dayIndex == 0 && day.person99999 == lastSunday99999) {
          return false;
        }
      }
    }

    return true;
  }

  /// 休班天数固定版验证
  bool _validateRolesOnly(
      List<DaySchedule> schedule, List<int> workingDays) {
    final count99999 = <String, int>{for (var n in names) n: 0};
    final countXieguan = <String, int>{for (var n in names) n: 0};

    for (final day in schedule) {
      count99999[day.person99999] = count99999[day.person99999]! + 1;
      countXieguan[day.personXieguan] = countXieguan[day.personXieguan]! + 1;
    }

    for (final name in names) {
      if (count99999[name] != 2) return false;
    }
    for (final name in names) {
      if (countXieguan[name] != 2) return false;
    }
    for (int i = 0; i < schedule.length - 1; i++) {
      if (schedule[i].person99999 == schedule[i + 1].person99999) {
        if (workingDays[i + 1] - workingDays[i] == 1) return false;
      }
    }
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
