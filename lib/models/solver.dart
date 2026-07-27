import 'schedule.dart';

/// 排班求解器 - 每人选1天休班，周六关门全员休班，
/// 休班日2人上班，其余日期3人全部上班（1人轮空）
class SimpleScheduleSolver {
  final List<String> names;
  final List<int> userRestDays; // 每人指定的1天休班(算法格式0=周一...6=周日)
  final int closingDay; // 关门日(算法格式)
  final String? lastSunday99999;

  SimpleScheduleSolver({
    required this.names,
    required this.userRestDays,
    this.closingDay = 6,
    this.lastSunday99999,
  });

  List<int> _getWorkingDays() {
    final days = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != closingDay) days.add(d);
    }
    return days;
  }

  /// 判断某天是否有人休班（返回休班人索引，无则返回-1）
  int _restPersonForDay(int dayIndex) {
    for (int i = 0; i < names.length; i++) {
      if (userRestDays[i] == dayIndex) return i;
    }
    return -1;
  }

  // ============ 完整求解（首次生成） ============

  /// 完整求解：枚举所有合法排班方案
  MapEntry<WeekSchedule?, int> solveWithCount(DateTime weekStart, {int offset = 0}) {
    final workingDays = _getWorkingDays();
    if (workingDays.length != 6) return MapEntry(null, 0);

    final allSolutions = <WeekSchedule>[];
    _enumRoles(0, workingDays, <DaySchedule>[], allSolutions, weekStart);
    if (allSolutions.isEmpty) return MapEntry(null, 0);
    return MapEntry(allSolutions[offset % allSolutions.length], allSolutions.length);
  }

  /// 枚举所有工作日的角色分配
  void _enumRoles(
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
    final restPersonIdx = _restPersonForDay(dayIndex);

    if (restPersonIdx >= 0) {
      // 当天1人休班，2人上班，各担任一个角色
      final restName = names[restPersonIdx];
      final workers = names.where((n) => n != restName).toList();
      for (int i = 0; i < 2; i++) {
        current.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: workers[i],
          personXieguan: workers[1 - i],
          personRest: restName,
        ));
        _enumRoles(idx + 1, workingDays, current, solutions, weekStart);
        current.removeLast();
      }
    } else {
      // 当天无人休班，3人全部上班，选2人分配角色，1人轮空
      // P(3,2) = 6 种排列
      for (int p99999 = 0; p99999 < 3; p99999++) {
        for (int pXieguan = 0; pXieguan < 3; pXieguan++) {
          if (p99999 == pXieguan) continue; // 不能同一人
          current.add(DaySchedule(
            dayIndex: dayIndex,
            person99999: names[p99999],
            personXieguan: names[pXieguan],
            personRest: '', // 无人休班
          ));
          _enumRoles(idx + 1, workingDays, current, solutions, weekStart);
          current.removeLast();
        }
      }
    }
  }

  // ============ 按用户约束求解（手动指定角色后刷新） ============

  /// 按用户填写的约束重新求解角色分配
  /// 先尝试带跨周约束求解，无解时自动放松跨周约束
  WeekSchedule? solveWithFixedRestAndConstraints(
    DateTime weekStart,
    List<int> workingDays,
    Map<int, Map<String, String?>> constraints,
  ) {
    final solutions = <WeekSchedule>[];
    _enumRolesWithConstraints(0, workingDays, <DaySchedule>[],
        solutions, weekStart, constraints);
    if (solutions.isNotEmpty) return solutions.first;
    
    // 带跨周约束无解，放松跨周约束再试一次
    if (lastSunday99999 != null) {
      final relaxed = SimpleScheduleSolver(
        names: names,
        userRestDays: userRestDays,
        closingDay: closingDay,
        lastSunday99999: null,
      ).solveWithFixedRestAndConstraints(
          weekStart, workingDays, constraints);
      return relaxed;
    }
    
    return null;
  }

  void _enumRolesWithConstraints(
    int idx,
    List<int> workingDays,
    List<DaySchedule> current,
    List<WeekSchedule> solutions,
    DateTime weekStart,
    Map<int, Map<String, String?>> constraints,
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
    final restPersonIdx = _restPersonForDay(dayIndex);
    final restName = restPersonIdx >= 0 ? names[restPersonIdx] : '';

    final workers = <String>[];
    if (restPersonIdx >= 0) {
      // 休班日：排除休班人
      for (final n in names) {
        if (n != restName) workers.add(n);
      }
    } else {
      // 全员上班日：所有3人都在
      workers.addAll(names);
    }

    final dayConstraint = constraints[dayIndex];
    final force99999 = dayConstraint?['99999'];
    final forceXieguan = dayConstraint?['协管'];

    // 约束可行性检查
    if (force99999 != null && !workers.contains(force99999)) return;
    if (forceXieguan != null && !workers.contains(forceXieguan)) return;
    if (force99999 != null && forceXieguan != null && force99999 == forceXieguan) return;

    if (force99999 != null || forceXieguan != null) {
      if (force99999 != null && forceXieguan != null) {
        // 同时指定了两人，唯一确定
        current.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: force99999,
          personXieguan: forceXieguan,
          personRest: restName,
        ));
        _enumRolesWithConstraints(idx + 1, workingDays, current,
            solutions, weekStart, constraints);
        current.removeLast();
      } else if (force99999 != null) {
        // 只指定了99999，枚举所有可能的协管
        for (final w in workers) {
          if (w == force99999) continue;
          current.add(DaySchedule(
            dayIndex: dayIndex,
            person99999: force99999,
            personXieguan: w,
            personRest: restName,
          ));
          _enumRolesWithConstraints(idx + 1, workingDays, current,
              solutions, weekStart, constraints);
          current.removeLast();
        }
      } else {
        // 只指定了协管，枚举所有可能的99999
        for (final w in workers) {
          if (w == forceXieguan) continue;
          current.add(DaySchedule(
            dayIndex: dayIndex,
            person99999: w,
            personXieguan: forceXieguan!,
            personRest: restName,
          ));
          _enumRolesWithConstraints(idx + 1, workingDays, current,
              solutions, weekStart, constraints);
          current.removeLast();
        }
      }
    } else if (workers.length == 2) {
      // 休班日：2人互换角色
      for (int i = 0; i < 2; i++) {
        current.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: workers[i],
          personXieguan: workers[1 - i],
          personRest: restName,
        ));
        _enumRolesWithConstraints(idx + 1, workingDays, current,
            solutions, weekStart, constraints);
        current.removeLast();
      }
    } else {
      // 全员上班日（3人）：P(3,2)=6种排列
      for (int p99999 = 0; p99999 < 3; p99999++) {
        for (int pXieguan = 0; pXieguan < 3; pXieguan++) {
          if (p99999 == pXieguan) continue;
          current.add(DaySchedule(
            dayIndex: dayIndex,
            person99999: names[p99999],
            personXieguan: names[pXieguan],
            personRest: '',
          ));
          _enumRolesWithConstraints(idx + 1, workingDays, current,
              solutions, weekStart, constraints);
          current.removeLast();
        }
      }
    }
  }

  // ============ 验证 ============

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

    // 连续两天不能同一人盯99999
    for (int i = 0; i < schedule.length - 1; i++) {
      if (schedule[i].person99999 == schedule[i + 1].person99999) {
        if (workingDays[i + 1] - workingDays[i] == 1) return false;
      }
    }

    // 上周日盯99999的人不能在本周一盯99999
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
