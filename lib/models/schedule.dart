/// 排班表一天的记录
class DaySchedule {
  final int dayIndex; // 0=周一...6=周日
  String person99999; // 盯99999柜台的人
  String personXieguan; // 盯协管的人
  String personRest; // 休班的人（当天不上班）
  String personNoonRest; // 中午休息的人（上班但午休）

  DaySchedule({
    required this.dayIndex,
    required this.person99999,
    required this.personXieguan,
    required this.personRest,
    String? personNoonRest,
  }) : personNoonRest = personNoonRest ?? '';

  Map<String, dynamic> toJson() => {
        'dayIndex': dayIndex,
        'person99999': person99999,
        'personXieguan': personXieguan,
        'personRest': personRest,
        'personNoonRest': personNoonRest,
      };

  factory DaySchedule.fromJson(Map<String, dynamic> json) => DaySchedule(
        dayIndex: json['dayIndex'],
        person99999: json['person99999'],
        personXieguan: json['personXieguan'],
        personRest: json['personRest'],
        personNoonRest: json['personNoonRest'] ?? '',
      );
}

/// 一周排班表
class WeekSchedule {
  final DateTime weekStart; // 周一日期
  final List<String> names;
  final int closingDay; // 关门日 0=周日...6=周六
  final List<int> restDays; // 每人指定的休班日
  final List<DaySchedule> days; // 排班天数

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
