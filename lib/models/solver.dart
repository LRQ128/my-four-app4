import 'schedule.dart';

/// 排班求解器 - 每人1天指定休班，系统自动补另1天，不重复
class SimpleScheduleSolver {
  final List<String> names;
  final List<int> userRestDays; // 每人指定的1天休班(算法格式0=周一...6=周日)
  final int closingDay; // 关门日(算法格式)
  final String? lastSunday99999;

  /// 在固定休班分配下，按用户约束求解 99999/协管
  /// [restPerDay]: 每个工作日的休班人索引，与 workingDays 顺序一致
  /// [constraints]: { dayIndex: { '99999': personName?, '协管': personName? } }
  WeekSchedule? solveWithFixedRestAndConstraints(
    DateTime weekStart,
    List<int> restPerDay,
    List<int> workingDays,
    Map<int, Map<String, String?>> constraints,
  ) {
    final solutions = <WeekSchedule>[];
    _enumRolesWithConstraints(0, workingDays, restPerDay, <DaySchedule>[],
        solutions, weekStart, constraints);
    return solutions.isNotEmpty ? solutions.first : null;
  }

  void _enumRolesWithConstraints(
    int idx,
    List<int> workingDays,
    List<int> restPerDay,
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
    final restName = names[restPerDay[idx]];
    final workers = <String>[];
    for (final n in names) {
      if (n != restName) workers.add(n);
    }

    final dayConstraint = constraints[dayIndex];
    final force99999 = dayConstraint?['99999'];
    final forceXieguan = dayConstraint?['协管'];

    // 约束可行性检查
    if (force99999 != null && !workers.contains(force99999)) return;
    if (forceXieguan != null && !workers.contains(forceXieguan)) return;
    if (force99999 != null && forceXieguan != null && force99999 == forceXieguan) return;

    if (force99999 != null || forceXieguan != null) {
      String p99999, pXieguan;
      if (force99999 != null && forceXieguan != null) {
        // 用户同时指定了两个人，直接使用
        p99999 = force99999;
        pXieguan = forceXieguan;
      } else if (force99999 != null) {
        p99999 = force99999;
        pXieguan = workers.firstWhere((w) => w != force99999);
      } else {
        pXieguan = forceXieguan!;
        p99999 = workers.firstWhere((w) => w != forceXieguan);
      }
      current.add(DaySchedule(
        dayIndex: dayIndex,
        person99999: p99999,
        personXieguan: pXieguan,
        personRest: restName,
      ));
      _enumRolesWithConstraints(idx + 1, workingDays, restPerDay, current,
          solutions, weekStart, constraints);
      current.removeLast();
    } else {
      for (int i = 0; i < 2; i++) {
        current.add(DaySchedule(
          dayIndex: dayIndex,
          person99999: workers[i],
          personXieguan: workers[1 - i],
          personRest: restName,
        ));
        _enumRolesWithConstraints(idx + 1, workingDays, restPerDay, current,
            solutions, weekStart, constraints);
        current.removeLast();
      }
    }
  }

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

  /// 完整求解：收集全部合法排班方案
  MapEntry<WeekSchedule?, int> solveWithCount(DateTime weekStart, {int offset = 0}) {
    final workingDays = _getWorkingDays();
    if (workingDays.length != 6) return MapEntry(null, 0);

    // 需要自动分配的休班日（未被用户指定的工作日）
    final autoDays = <int>[];
    final specified = <int>{...userRestDays};
    for (final d in workingDays) {
      if (!specified.contains(d)) autoDays.add(d);
    }
    if (autoDays.length != 3) return MapEntry(null, 0);

    final allSolutions = <WeekSchedule>[];
    _enumRestAssign(0, autoDays, <int>[], allSolutions, workingDays, weekStart);
    if (allSolutions.isEmpty) return MapEntry(null, 0);
    return MapEntry(allSolutions[offset % allSolutions.length], allSolutions.length);
  }

  /// 枚举3个自动休班日分配给3个人的全排列
  void _enumRestAssign(
    int idx,
    List<int> autoDays,
    List<int> assigned, // assigned[pIdx] = autoDayIndex
    List<WeekSchedule> allSolutions,
    List<int> workingDays,
    DateTime weekStart,
  ) {
    if (idx >= 3) {
      // 构建 restPerDay：[每个工作日的休班人索引]
      final restPerDay = <int>[];
      for (final d in workingDays) {
        int? p;
        for (int i = 0; i < 3; i++) {
          if (userRestDays[i] == d) { p = i; break; }
        }
        if (p == null) {
          for (int i = 0; i < 3; i++) {
            if (autoDays[assigned[i]] == d) { p = i; break; }
          }
        }
        restPerDay.add(p!);
      }

      _enumRoles(0, workingDays, restPerDay, <DaySchedule>[],
          allSolutions, weekStart);
      return;
    }

    for (int p = 0; p < 3; p++) {
      if (assigned.contains(p)) continue; // 每人只能1天自动休班
      if (userRestDays[p] == autoDays[idx]) continue; // 不能和指定休班冲突
      assigned.add(p);
      _enumRestAssign(idx + 1, autoDays, assigned, allSolutions,
          workingDays, weekStart);
      assigned.removeLast();
    }
  }

  /// 固定休班分配下，枚举99999/协管
  void _enumRoles(
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
          restDays: List.from(userRestDays), // 只需保留指定的3天
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

    for (int i = 0; i < 2; i++) {
      current.add(DaySchedule(
        dayIndex: dayIndex,
        person99999: workers[i],
        personXieguan: workers[1 - i],
        personRest: restName,
      ));
      _enumRoles(idx + 1, workingDays, restPerDay, current, solutions, weekStart);
      current.removeLast();
    }
  }

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
