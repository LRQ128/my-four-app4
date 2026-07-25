import 'schedule.dart';

/// 排班求解器 - 每个柜员的2天休班均由用户指定，系统只分配99999/协管
class SimpleScheduleSolver {
  final List<String> names;
  final List<int> userRestDays; // [p1_d1, p1_d2, p2_d1, p2_d2, p3_d1, p3_d2]
  final int closingDay; // 算法格式 0=周一...6=周日
  final String? lastSunday99999; // 上周日盯99999的人(跨周约束)

  SimpleScheduleSolver({
    required this.names,
    required this.userRestDays,
    this.closingDay = 6,
    this.lastSunday99999,
  });

  /// 验证用户设定的休班日是否合法
  /// 每人恰好2天，不能重复，6天覆盖全部工作日
  bool validateRestDays(DateTime weekStart) {
    final workingDays = _getWorkingDays();
    
    // 每人必须恰好有2天休班
    for (int i = 0; i < names.length; i++) {
      final d1 = userRestDays[i * 2];
      final d2 = userRestDays[i * 2 + 1];
      if (d1 == d2) return false; // 同一天不能休班2次
      if (!workingDays.contains(d1) || !workingDays.contains(d2)) return false; // 必须在工作日内
    }

    // 6个休班日必须覆盖全部6个工作日（每人2天）
    final allRest = <int>{...userRestDays};
    if (allRest.length != 6) return false;
    for (final d in workingDays) {
      if (!allRest.contains(d)) return false;
    }

    return true;
  }

  /// 构建restPeoplePerDay：每个工作日的休班人索引
  List<int> _buildRestPerDay(List<int> workingDays) {
    return workingDays.map((di) {
      for (int i = 0; i < names.length; i++) {
        if (userRestDays[i * 2] == di || userRestDays[i * 2 + 1] == di) return i;
      }
      return 0; // 不应走到这里
    }).toList();
  }

  List<int> _getWorkingDays() {
    final days = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != closingDay) days.add(d);
    }
    return days;
  }

  /// 求解排班，所有休班日已由用户指定，只分配99999/协管
  /// 返回 [schedule, totalCount]
  MapEntry<WeekSchedule?, int> solveWithCount(DateTime weekStart, {int offset = 0}) {
    if (!validateRestDays(weekStart)) return MapEntry(null, 0);

    final workingDays = _getWorkingDays();
    final restPerDay = _buildRestPerDay(workingDays);
    final solutions = <WeekSchedule>[];
    _backtrack(0, workingDays, restPerDay, <DaySchedule>[], solutions, weekStart);

    if (solutions.isEmpty) return MapEntry(null, 0);
    return MapEntry(solutions[offset % solutions.length], solutions.length);
  }

  void _backtrack(
    int idx,
    List<int> workingDays,
    List<int> restPerDay,
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
    final restName = names[restPerDay[idx]];
    final workers = <String>[];
    for (final n in names) {
      if (n != restName) workers.add(n);
    }

    // 2种分配：workers[0]=99999, workers[1]=协管 或 反过来
    for (int i = 0; i < 2; i++) {
      current.add(DaySchedule(
        dayIndex: dayIndex,
        person99999: workers[i],
        personXieguan: workers[1 - i],
        personRest: restName,
      ));
      _backtrack(idx + 1, workingDays, restPerDay, current, solutions, weekStart);
      current.removeLast();
    }
  }

  /// 验证：每人2天99999、2天协管、同人99999不连续、跨周约束
  bool _validate(List<DaySchedule> schedule, List<int> workingDays) {
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

    // 同人99999不能连续日历工作日
    for (int i = 0; i < schedule.length - 1; i++) {
      if (schedule[i].person99999 == schedule[i + 1].person99999) {
        if (workingDays[i + 1] - workingDays[i] == 1) return false;
      }
    }

    // 跨周约束：上周日盯99999的人，周一不能盯
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
