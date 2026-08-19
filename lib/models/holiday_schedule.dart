/// ============================================================
/// 假期长排班 - 数据模型
/// 专为五一/十一/春节等法定长假跨周排班设计
/// ============================================================

/// 日期工具
class DateKey {
  /// 转 yyyyMMdd 整数键（用于比较/存储日期相等性）
  static int key(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  /// 归一化到当天 0 点
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String toStringKey(int k) {
    final y = k ~/ 10000;
    final m = (k % 10000) ~/ 100;
    final d = k % 100;
    return '$y-$m-$d';
  }
}

/// 假期排班单日记录
class HolidayDay {
  DateTime date; // 具体日期（当天0点）
  int dateKey; // yyyyMMdd
  bool isClosed; // 是否关门（关门=全员休）
  String person99999; // 盯99999的人
  String personXieguan; // 盯协管的人
  String personRest; // 当天休班的人（'' 表示无人休班，3人在岗）
  String personNoonRest; // 中午休息的人

  HolidayDay({
    required this.date,
    required this.dateKey,
    required this.isClosed,
    required this.person99999,
    required this.personXieguan,
    this.personRest = '',
    this.personNoonRest = '',
  });

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'dateKey': dateKey,
        'isClosed': isClosed,
        'person99999': person99999,
        'personXieguan': personXieguan,
        'personRest': personRest,
        'personNoonRest': personNoonRest,
      };

  factory HolidayDay.fromJson(Map<String, dynamic> json) => HolidayDay(
        date: DateTime.parse(json['date']),
        dateKey: json['dateKey'],
        isClosed: json['isClosed'] ?? false,
        person99999: json['person99999'] ?? '',
        personXieguan: json['personXieguan'] ?? '',
        personRest: json['personRest'] ?? '',
        personNoonRest: json['personNoonRest'] ?? '',
      );
}

/// 假期排班（覆盖假期所横跨的两周）
class HolidaySchedule {
  String name; // 假期名称，如 "2026年国庆"
  DateTime holidayStart; // 假期开始日期
  DateTime holidayEnd; // 假期结束日期
  DateTime coverStart; // 覆盖范围开始（第一周周一）
  DateTime coverEnd; // 覆盖范围结束（最后一日，通常周日）
  List<String> names; // 柜员
  List<int> closedDays; // 关门日期 yyyyMMdd 列表
  int targetRestDays; // 每人休假总天数
  int locked; // 0=未固定 1=已固定
  List<HolidayDay> days; // 覆盖范围内每天的排班

  HolidaySchedule({
    required this.name,
    required this.holidayStart,
    required this.holidayEnd,
    required this.coverStart,
    required this.coverEnd,
    required this.names,
    required this.closedDays,
    required this.targetRestDays,
    required this.days,
    this.locked = 0,
  });

  /// 关门天数
  int get closedCount => closedDays.length;

  /// 开门(上班)天数
  int get openingCount => days.where((d) => !d.isClosed).length;

  /// 覆盖天数
  int get coverDays => days.length;

  /// 找到某天的记录
  HolidayDay? dayAt(DateTime date) {
    final k = DateKey.key(date);
    for (final d in days) {
      if (d.dateKey == k) return d;
    }
    return null;
  }

  /// 某位柜员的休假天数
  int restCountOf(String name) =>
      days.where((d) => d.personRest == name).length +
      days.where((d) => d.isClosed).length; // 关门日全员休

  /// 某位柜员盯99999的次数
  int count99999Of(String name) =>
      days.where((d) => d.person99999 == name).length;

  /// 某位柜员盯协管的次数
  int countXieguanOf(String name) =>
      days.where((d) => d.personXieguan == name).length;

  /// 日期范围显示文本，如 "9/30 - 10/13"
  String dateRangeText() {
    final first = days.first.date;
    final last = days.last.date;
    return '${first.month}/${first.day} - ${last.month}/${last.day}';
  }

  /// 假期区间文本
  String holidayRangeText() {
    return '${holidayStart.month}/${holidayStart.day} - ${holidayEnd.month}/${holidayEnd.day}';
  }

  /// 每周名称（覆盖横跨两周时会有两个周标题）
  Map<String, List<HolidayDay>> byWeek() {
    final weeks = <String, List<HolidayDay>>{};
    for (final d in days) {
      // 该日期所在周的周一
      final monday = d.date.subtract(Duration(days: d.date.weekday - 1));
      final label = '${monday.month}/${monday.day}周';
      weeks.putIfAbsent(label, () => []).add(d);
    }
    return weeks;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'holidayStart': holidayStart.toIso8601String(),
        'holidayEnd': holidayEnd.toIso8601String(),
        'coverStart': coverStart.toIso8601String(),
        'coverEnd': coverEnd.toIso8601String(),
        'names': names,
        'closedDays': closedDays,
        'targetRestDays': targetRestDays,
        'days': days.map((d) => d.toJson()).toList(),
        'locked': locked,
      };

  factory HolidaySchedule.fromJson(Map<String, dynamic> json) {
    return HolidaySchedule(
      name: json['name'],
      holidayStart: DateTime.parse(json['holidayStart']),
      holidayEnd: DateTime.parse(json['holidayEnd']),
      coverStart: DateTime.parse(json['coverStart']),
      coverEnd: DateTime.parse(json['coverEnd']),
      names: List<String>.from(json['names']),
      closedDays:
          (json['closedDays'] as List).map((e) => e as int).toList(),
      targetRestDays: json['targetRestDays'],
      days: (json['days'] as List)
          .map((d) => HolidayDay.fromJson(d))
          .toList(),
      locked: json['locked'] ?? 0,
    );
  }
}
