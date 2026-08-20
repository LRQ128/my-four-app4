import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models/holiday_schedule.dart';
import 'models/holiday_solver.dart';

/// ===================== 假期快捷模板 =====================
class HolidayPreset {
  final String label;
  final DateTime Function(int year) start;
  final int durationDays;
  const HolidayPreset(this.label, this.start, this.durationDays);
}

List<HolidayPreset> _presets() {
  final chunjie = <int, (int, int)>{
    2023: (1, 22), 2024: (2, 10), 2025: (1, 29), 2026: (2, 17),
    2027: (2, 6), 2028: (1, 26), 2029: (2, 13), 2030: (2, 3),
    2031: (1, 23), 2032: (2, 11), 2033: (1, 31),
  };
  final qingming = <int, (int, int)>{
    2024: (4, 4), 2025: (4, 4), 2026: (4, 5), 2027: (4, 5),
    2028: (4, 4), 2029: (4, 4), 2030: (4, 5), 2031: (4, 5), 2032: (4, 4),
  };
  final duanwu = <int, (int, int)>{
    2024: (6, 10), 2025: (5, 31), 2026: (6, 19), 2027: (6, 9),
    2028: (5, 28), 2029: (6, 16), 2030: (6, 5), 2031: (6, 25),
    2032: (6, 12),
  };
  final zhongqiu = <int, (int, int)>{
    2024: (9, 17), 2025: (10, 6), 2026: (9, 25), 2027: (9, 15),
    2028: (10, 3), 2029: (9, 22), 2030: (9, 12), 2031: (10, 1),
    2032: (9, 19),
  };
  DateTime from(Map<int, (int, int)> table, int year,
      {int fm = 2, int fd = 17}) {
    final e = table[year];
    return e != null ? DateTime(year, e.$1, e.$2) : DateTime(year, fm, fd);
  }
  return [
    HolidayPreset('春节', (y) => from(chunjie, y, fm: 2, fd: 17), 8),
    HolidayPreset('清明', (y) => from(qingming, y, fm: 4, fd: 5), 3),
    HolidayPreset('五一', (y) => DateTime(y, 5, 1), 5),
    HolidayPreset('端午', (y) => from(duanwu, y, fm: 6, fd: 19), 3),
    HolidayPreset('中秋', (y) => from(zhongqiu, y, fm: 9, fd: 25), 3),
    HolidayPreset('国庆', (y) => DateTime(y, 10, 1), 7),
    HolidayPreset('元旦', (y) => DateTime(y, 1, 1), 3),
  ];
}

/// ===================== 假期排班数据库 =====================
class HolidayDb {
  static Database? _db;
  static Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/schedule.db';
    _db = await openDatabase(path, version: 3,
        onCreate: (db, v) async => _ensureTable(db),
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 3) await _ensureTable(db);
        });
    return _db!;
  }

  static Future<void> _ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS holiday_schedules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        holiday_name TEXT NOT NULL,
        holiday_start TEXT NOT NULL,
        holiday_end TEXT NOT NULL,
        cover_start TEXT NOT NULL,
        cover_end TEXT NOT NULL,
        names TEXT NOT NULL,
        closed_days TEXT NOT NULL,
        target_rest_days INTEGER NOT NULL,
        days_json TEXT NOT NULL,
        locked INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> save(HolidaySchedule s) async {
    final db = await database;
    final existing = await db.query('holiday_schedules',
        columns: ['id'],
        where: 'cover_start = ? AND holiday_name = ?',
        whereArgs: [s.coverStart.toIso8601String(), s.name]);
    final vals = {
      'holiday_name': s.name,
      'holiday_start': s.holidayStart.toIso8601String(),
      'holiday_end': s.holidayEnd.toIso8601String(),
      'cover_start': s.coverStart.toIso8601String(),
      'cover_end': s.coverEnd.toIso8601String(),
      'names': s.names.join(','),
      'closed_days': (s.closedDays.isEmpty)
          ? ''
          : s.closedDays.join(','),
      'target_rest_days': s.targetRestDays,
      'days_json': jsonEncode(s.days.map((d) => d.toJson()).toList()),
      'locked': s.locked,
    };
    if (existing.isNotEmpty) {
      await db.update('holiday_schedules', vals,
          where: 'cover_start = ? AND holiday_name = ?',
          whereArgs: [s.coverStart.toIso8601String(), s.name]);
    } else {
      vals['created_at'] = DateTime.now().toIso8601String();
      await db.insert('holiday_schedules', vals);
    }
  }

  static Future<void> setLocked(int id, bool locked) async {
    final db = await database;
    await db.update('holiday_schedules', {'locked': locked ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<dynamic>> loadAll() async {
    final db = await database;
    return db.query('holiday_schedules', orderBy: 'created_at DESC');
  }

  static HolidaySchedule fromRow(Map<String, dynamic> m) {
    return HolidaySchedule(
      name: m['holiday_name'],
      holidayStart: DateTime.parse(m['holiday_start']),
      holidayEnd: DateTime.parse(m['holiday_end']),
      coverStart: DateTime.parse(m['cover_start']),
      coverEnd: DateTime.parse(m['cover_end']),
      names: (m['names'] as String).split(','),
      closedDays: (m['closed_days'] as String).isEmpty
          ? <int>[]
          : (m['closed_days'] as String).split(',').map(int.parse).toList(),
      targetRestDays: m['target_rest_days'] as int,
      days: (jsonDecode(m['days_json'] as String) as List)
          .map((e) => HolidayDay.fromJson(e))
          .toList(),
      locked: (m['locked'] as int?) ?? 0,
    );
  }
}

/// ===================== 假期排班主 Tab =====================
class HolidayTab extends StatefulWidget {
  const HolidayTab({super.key});
  @override
  State<HolidayTab> createState() => _HolidayTabState();
}

class _HolidayTabState extends State<HolidayTab> {
  List<String> _names = ['张三', '李四', '王五'];
  HolidaySchedule? _current;
  List<dynamic> _rows = []; // 数据库行（含 id）
  bool _viewHistory = false;
  HolidaySchedule? _viewing;
  int? _expandedIndex;
  int _target = 4;
  static const String _autoTag = '自动分配';
  final _nameCtl = TextEditingController();
  bool _nameCtlInit = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final namesStr = await _loadSetting('names');
    final rows = await HolidayDb.loadAll();
    if (mounted) {
      setState(() {
        if (namesStr != null && namesStr.isNotEmpty) {
          _names = namesStr.split(',');
        }
        _rows = rows;
      });
    }
  }

  Future<String?> _loadSetting(String key) async {
    try {
      final db = await HolidayDb.database;
      final maps =
          await db.query('settings', where: 'key = ?', whereArgs: [key]);
      if (maps.isEmpty) return null;
      return maps.first['value'] as String;
    } catch (_) {
      return null;
    }
  }

  int? _idOf(HolidaySchedule s) {
    for (final r in _rows) {
      if (r['cover_start'] == s.coverStart.toIso8601String() &&
          r['holiday_name'] == s.name) {
        return r['id'] as int;
      }
    }
    return null;
  }

  String _dayName(int i) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][i];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 顶部操作
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      icon: Icon(Icons.calendar_month, size: 18),
                      label: Text('排班表')),
                  ButtonSegment(
                      value: true,
                      icon: Icon(Icons.history, size: 18),
                      label: Text('历史记录')),
                ],
                selected: {_viewHistory},
                onSelectionChanged: (s) =>
                    setState(() => _viewHistory = s.first),
              ),
              const Spacer(),
              if (!_viewHistory)
                ElevatedButton.icon(
                  onPressed: _showCreateDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新假期排班'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _viewHistory ? _buildHistory() : _buildCurrent(),
        ),
      ],
    );
  }

  Widget _buildCurrent() {
    if (_current == null) return _buildEmpty();
    final s = _current!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题卡
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.flight_takeoff, color: Colors.orange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(s.name,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                      ),
                      if (s.locked == 1)
                        const Icon(Icons.lock, color: Colors.green, size: 20),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('假期：${s.holidayRangeText()}（共 '
                      '${s.holidayEnd.difference(s.holidayStart).inDays + 1} 天）',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                  Text(
                      '排班范围：${s.dateRangeText()}'
                      '（横跨 ${s.coverDays} 天，关门 ${s.closedCount} 天，上班 ${s.openingCount} 天）',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                  Text('每人休假 ${s.targetRestDays} 天',
                      style: const TextStyle(
                          fontSize: 14,
                          color: Colors.blue,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _showRefreshDialog,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('刷新'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _toggleLock,
                        icon: Icon(
                            s.locked == 1 ? Icons.lock : Icons.lock_open,
                            size: 16),
                        label: Text(s.locked == 1 ? '已固定' : '固定'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _exportToImage,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('导出'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          // 按周分组展示
          ..._buildWeekSections(s),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('休假统计',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  ...s.names.map((n) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SizedBox(
                              width: 64,
                              child: Text(n,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold))),
                          Text(
                              '休假 ${s.restCountOf(n)} 天   99999×${s.count99999Of(n)}   协管×${s.countXieguanOf(n)}'),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildWeekSections(HolidaySchedule s) {
    final weeks = s.byWeek();
    final sections = <Widget>[];
    weeks.forEach((label, days) {
      sections.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('📍 $label',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ));
      sections.add(SizedBox(
        height: 190,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: days.length,
          itemBuilder: (context, i) => _dayCard(days[i]),
        ),
      ));
      sections.add(const SizedBox(height: 8));
    });
    return sections;
  }

  Widget _dayCard(HolidayDay d) {
    final today = DateTime.now();
    final isToday = today.year == d.date.year &&
        today.month == d.date.month &&
        today.day == d.date.day;
    final closed = d.isClosed;
    return Container(
      width: 132,
      margin: const EdgeInsets.only(right: 8),
      child: Card(
        color: closed
            ? Colors.grey[200]
            : (isToday ? Colors.blue[50] : null),
        elevation: closed ? 0 : 1,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_dayName(d.date.weekday - 1),
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: closed ? Colors.grey[600] : null)),
                  if (isToday && !closed)
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(8)),
                      child: const Text('今天',
                          style: TextStyle(
                              color: Colors.white, fontSize: 9)),
                    ),
                ],
              ),
              Text('${d.date.month}/${d.date.day}',
                  style: TextStyle(
                      fontSize: 12,
                      color: closed ? Colors.grey[600] : Colors.grey[500])),
              const Divider(height: 10),
              if (closed) ...[
                const Icon(Icons.lock, color: Colors.grey, size: 26),
                const SizedBox(height: 2),
                const Text('关门', style: TextStyle(color: Colors.grey)),
              ] else ...[
                _slot('🏦99999', d.person99999),
                const SizedBox(height: 3),
                _slot('🤝协管', d.personXieguan),
                const SizedBox(height: 5),
                if (d.personRest.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: Colors.orange[100],
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('休班 ${d.personRest}',
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _slot(String label, String name) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label,
            style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        const SizedBox(width: 3),
        Text(name,
            style:
                const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
      ],
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.event_note, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          const Text('暂无假期排班',
              style: TextStyle(fontSize: 18, color: Colors.grey)),
          const SizedBox(height: 8),
          Text('为五一/十一/春节等长假创建跨两周的排班模板',
              style: TextStyle(color: Colors.grey[500])),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _showCreateDialog,
            icon: const Icon(Icons.add),
            label: const Text('新建假期排班'),
          ),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    final list = _rows.where((r) => (r['locked'] as int) == 1).toList();
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 70, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text('暂无固定假期排班', style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 6),
            Text('生成后点击🔒固定即可在此查看',
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final s = HolidayDb.fromRow(list[index]);
        final expanded = _expandedIndex == index;
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: () => setState(() {
              _expandedIndex = expanded ? null : index;
            }),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock, size: 16, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${s.name}  ${s.dateRangeText()}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                      Icon(expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                          color: Colors.grey),
                    ],
                  ),
                  Text('每人休假 ${s.targetRestDays} 天 · 关门 ${s.closedCount} 天',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  if (expanded) ...[
                    const Divider(),
                    ...s.names.map((n) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                              '$n: 休假${s.restCountOf(n)}天  99999×${s.count99999Of(n)}  协管×${s.countXieguanOf(n)}',
                              style: const TextStyle(fontSize: 13)),
                        )),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _current = s;
                          _viewHistory = false;
                          _expandedIndex = null;
                        }),
                        icon: const Icon(Icons.visibility, size: 18),
                        label: const Text('查看此排班'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ===================== 创建/配置对话框 =====================
  Future<void> _showCreateDialog() async {
    final now = DateTime.now();
    final year = now.year;
    var preset = _presets().firstWhere(
        (p) => p.label == '国庆',
        orElse: () => _presets().first);
    DateTime start = preset.start(year);
    DateTime end = start.add(Duration(days: preset.durationDays - 1));
    Set<int> closed = _rangeKeys(start, end); // 默认假期区间内全部关门
    _nameCtl.text = '${year}年${preset.label}';
    var holidayName = _nameCtl.text;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlg) {
          DateTime Function() computeCover = () {
            final s = DateKey.dateOnly(start);
            final e = DateKey.dateOnly(end);
            final monday = s.subtract(Duration(days: s.weekday - 1));
            final sunday = e.add(Duration(days: 7 - e.weekday));
            return monday;
          };
          // 覆盖范围
          final cs = computeCover();
          final es = DateKey.dateOnly(end)
              .add(Duration(days: 7 - end.weekday));
          // 覆盖内所有天
          final coverDates = <DateTime>[];
          var c = cs;
          while (!c.isAfter(es)) {
            coverDates.add(c);
            c = c.add(const Duration(days: 1));
          }
          final C = closed.length;
          final O = coverDates.length - C;
          final minT = C;
          final maxT = C + O ~/ 3;
          return Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 620),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('新建假期排班',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    // 假期类型
                    DropdownButtonFormField<String>(
                      value: preset.label,
                      decoration: const InputDecoration(
                          labelText: '假期类型', border: OutlineInputBorder()),
                      items: _presets()
                          .map((p) => DropdownMenuItem(
                              value: p.label, child: Text(p.label)))
                          .toList(),
                      onChanged: (v) {
                        final p = _presets().firstWhere((x) => x.label == v);
                        final newStart = p.start(year);
                        final newEnd =
                            newStart.add(Duration(days: p.durationDays - 1));
                        setDlg(() {
                          preset = p;
                          start = newStart;
                          end = newEnd;
                          _nameCtl.text = '${year}年${p.label}';
                          holidayName = _nameCtl.text;
                          closed = _rangeKeys(newStart, newEnd);
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    // 年份
                    DropdownButtonFormField<int>(
                      value: year,
                      decoration: const InputDecoration(
                          labelText: '年份', border: OutlineInputBorder()),
                      items: List.generate(10, (i) => year - 1 + i)
                          .map((y) => DropdownMenuItem(
                              value: y,
                              child: Text('${y}年')))
                          .toList(),
                      onChanged: (v) {
                        final newStart = preset.start(v!);
                        final newEnd =
                            newStart.add(Duration(days: preset.durationDays - 1));
                        setDlg(() {
                          _nameCtl.text = '${v}年${preset.label}';
                          holidayName = _nameCtl.text;
                          start = newStart;
                          end = newEnd;
                          closed = _rangeKeys(newStart, newEnd);
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    // 起止日期
                    Row(children: [
                      Expanded(
                        child: _datePickerField('开始日期', start, (v) {
                          setDlg(() => start = v!);
                        }),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _datePickerField('结束日期', end, (v) {
                          setDlg(() => end = v!);
                        }),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameCtl,
                      decoration: const InputDecoration(
                          labelText: '假期名称',
                          border: OutlineInputBorder()),
                      onChanged: (v) => holidayName = v,
                    ),
                    const SizedBox(height: 12),
                    const Text('设置覆盖范围内每天的开门/关门（点击切换）',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 120,
                      child: GridView.count(
                        crossAxisCount: 4,
                        childAspectRatio: 1.1,
                        children: coverDates.map((d) {
                          final k = DateKey.key(d);
                          final isClosed = closed.contains(k);
                          final inHoliday =
                              DateKey.key(start) <= k && k <= DateKey.key(end);
                          return Padding(
                            padding: const EdgeInsets.all(3),
                            child: InkWell(
                              onTap: () => setDlg(() {
                                if (isClosed) {
                                  closed.remove(k);
                                } else {
                                  closed.add(k);
                                }
                              }),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isClosed
                                      ? Colors.grey[350]
                                      : (inHoliday
                                          ? Colors.green[100]
                                          : Colors.blue[50]),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: isClosed
                                          ? Colors.grey
                                          : (inHoliday
                                              ? Colors.green
                                              : Colors.blue.shade300)),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text('${d.month}/${d.day}',
                                        style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 2),
                                    Icon(
                                      isClosed
                                          ? Icons.lock
                                          : Icons.store,
                                      size: 16,
                                      color: isClosed
                                          ? Colors.grey[700]
                                          : (inHoliday
                                              ? Colors.green[800]
                                              : Colors.blue[700]),
                                    ),
                                    Text(isClosed ? '关' : '开',
                                        style: TextStyle(
                                            fontSize: 9,
                                            color: isClosed
                                                ? Colors.grey[700]
                                                : Colors.green[800])),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                        '当前关门 $C 天 · 上班 $O 天\n每人可选休假天数：$minT ~ $maxT 天'
                        '（关门日已全员休 $C 天，需保证每人休班 ≥ 关门天数）',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[700],
                            height: 1.5)),
                    const SizedBox(height: 8),
                    if (maxT >= minT)
                      DropdownButtonFormField<int>(
                        value: _clamp(_target, minT, maxT),
                        decoration: const InputDecoration(
                            labelText: '每人休假天数',
                            border: OutlineInputBorder()),
                        items: List.generate(
                                maxT - minT + 1, (i) => minT + i)
                            .map((t) => DropdownMenuItem(
                                value: t, child: Text('$t 天')))
                            .toList(),
                        onChanged: (v) => _target = v!,
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              if (start.isAfter(end)) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text('开始日期不能晚于结束日期'),
                                      backgroundColor: Colors.red),
                                );
                                return;
                              }
                              Navigator.pop(ctx);
                              _generate(
                                  holidayName, start, end, closed, _target);
                            },
                            icon: const Icon(Icons.auto_awesome, size: 18),
                            label: const Text('生成'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }

  int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  Set<int> _rangeKeys(DateTime a, DateTime b) {
    final s = DateKey.dateOnly(a);
    final e = DateKey.dateOnly(b);
    final out = <int>{};
    var c = s;
    while (!c.isAfter(e)) {
      out.add(DateKey.key(c));
      c = c.add(const Duration(days: 1));
    }
    return out;
  }

  Widget _datePickerField(String label, DateTime value, ValueChanged<DateTime?> onPick) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime(2040),
          locale: const Locale('zh'),
        );
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        child: Text('${value.year}/${value.month}/${value.day}',
            style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  Future<void> _generate(String name, DateTime start, DateTime end,
      Set<int> closed, int targetRestDays) async {
    final cover = HolidayScheduleSolver.computeCover(start, end);
    final solver = HolidayScheduleSolver(
      names: _names,
      targetRestDays: targetRestDays,
      closedDayKeys: closed,
      coverStart: cover.$1,
      coverEnd: cover.$2,
    );
    final result = solver.solve(
        name: name, holidayStart: start, holidayEnd: end);

    if (!mounted) return;
    if (!result.feasible) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(result.messages.join('\n')),
            backgroundColor: Colors.orange),
      );
      return;
    }
    final s = result.schedule!;
    await HolidayDb.save(s);
    await _load();
    if (!mounted) return;
    setState(() {
      _current = s;
      _target = targetRestDays;
    });
    _showPlanInfo(result.messages);
  }

  void _showPlanInfo(List<String> msgs) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.calculate, color: Colors.blue),
          SizedBox(width: 8),
          Text('排班计算过程'),
        ]),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final m in msgs) Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(m, style: const TextStyle(fontSize: 13)),
              )],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _toggleLock() async {
    final s = _current;
    if (s == null) return;
    final id = _idOf(s);
    if (id == null) return;
    final locked = s.locked != 1;
    await HolidayDb.setLocked(id, locked);
    s.locked = locked ? 1 : 0;
    await _load();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(locked ? '✅ 已固定该假期排班' : '已取消固定'),
          backgroundColor: locked ? Colors.green : Colors.grey));
    }
  }

  // ===================== 刷新对话框 =====================
  Future<void> _showRefreshDialog() async {
    final s = _current;
    if (s == null) return;
    final openDays = s.days.where((d) => !d.isClosed).toList();

    // 每个开门日的编辑状态
    final edit = <int, bool>{}; // key -> 是否手动
    final restSel = <int, String>{}; // ''=无人 或 人名
    final p9Sel = <int, String>{};
    final pxSel = <int, String>{};
    for (final d in openDays) {
      edit[d.dateKey] = false;
      restSel[d.dateKey] = _autoTag;
      p9Sel[d.dateKey] = _autoTag;
      pxSel[d.dateKey] = _autoTag;
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Row(children: [
            Icon(Icons.edit_note, size: 22),
            SizedBox(width: 8),
            Text('手动指定（可改休班人与角色）'),
          ]),
          content: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '勾选"手动"后可为该天指定休班人/角色；未勾选天由系统自动保持每人休假总数不变。',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    const SizedBox(height: 8),
                    for (final d in openDays) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Text('${d.date.month}/${d.date.day} '
                                  '${_dayName(d.date.weekday - 1)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                              const Spacer(),
                              Switch(
                                value: edit[d.dateKey]!,
                                onChanged: (v) =>
                                    setDlg(() => edit[d.dateKey] = v),
                              ),
                              const Text('手动', style: TextStyle(fontSize: 11)),
                            ]),
                            Row(children: [
                              Expanded(
                                child: _smallDropdown(
                                  '休班人',
                                  restSel[d.dateKey]!,
                                  [_autoTag, '无人休班', ..._names],
                                  (v) => setDlg(() =>
                                      restSel[d.dateKey] =
                                          v == '无人休班' ? '' : v),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            Row(children: [
                              Expanded(
                                child: _smallDropdown(
                                  '盯99999',
                                  p9Sel[d.dateKey]!,
                                  [_autoTag, ..._names],
                                  (v) => setDlg(
                                      () => p9Sel[d.dateKey] = v),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _smallDropdown(
                                  '协管',
                                  pxSel[d.dateKey]!,
                                  [_autoTag, ..._names],
                                  (v) => setDlg(
                                      () => pxSel[d.dateKey] = v),
                                ),
                              ),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            ElevatedButton.icon(
              onPressed: () {
                final cons = <int, RoleConstraint>{};
                for (final d in openDays) {
                  final k = d.dateKey;
                  if (!edit[k]!) continue; // 未手动 → 自动
                  cons[k] = RoleConstraint(
                    forceRest: restSel[k] == _autoTag ? null : restSel[k],
                    force99999: p9Sel[k] == _autoTag ? null : p9Sel[k],
                    forceXieguan:
                        pxSel[k] == _autoTag ? null : pxSel[k],
                  );
                }
                Navigator.pop(ctx);
                _applyRefresh(cons);
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('确定刷新'),
            ),
          ],
        );
      }),
    );
  }

  Widget _smallDropdown(
      String label, String value, List<String> opts, ValueChanged<String> onChanged) {
    return DropdownButtonFormField<String>(
      value:
          opts.contains(value) ? value : (opts.isNotEmpty ? opts.first : ''),
      isDense: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      items: opts
          .map((o) => DropdownMenuItem(value: o, child: Text(o)))
          .toList(),
      onChanged: (v) => onChanged(v!),
    );
  }

  Future<void> _applyRefresh(Map<int, RoleConstraint> constraints) async {
    final s = _current;
    if (s == null) return;
    final solver = HolidayScheduleSolver(
      names: _names,
      targetRestDays: s.targetRestDays,
      closedDayKeys: s.closedDays.toSet(),
      coverStart: s.coverStart,
      coverEnd: s.coverEnd,
    );
    final result = solver.solve(
        name: s.name,
        holidayStart: s.holidayStart,
        holidayEnd: s.holidayEnd,
        constraints: constraints);
    if (!mounted) return;
    if (!result.feasible) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.messages.join('\n')),
          backgroundColor: Colors.red));
      return;
    }
    final ns = result.schedule!;
    ns.locked = s.locked;
    await HolidayDb.save(ns);
    await _load();
    if (mounted) {
      setState(() => _current = ns);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ 已刷新'), backgroundColor: Colors.green));
    }
  }

  // ===================== 导出 =====================
  Future<void> _exportToImage() async {
    final s = _current;
    if (s == null) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ExportDialog(
        schedule: s,
        dayName: _dayName,
        onDone: (success, msg) {
          if (ctx.mounted) Navigator.pop(ctx);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(msg),
                backgroundColor: success ? Colors.green : Colors.red));
          }
        },
      ),
    );
  }
}

/// ===================== 导出对话框 =====================
class _ExportDialog extends StatefulWidget {
  final HolidaySchedule schedule;
  final String Function(int) dayName;
  final void Function(bool, String) onDone;
  const _ExportDialog(
      {required this.schedule,
      required this.dayName,
      required this.onDone});
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 250), _capture);
    });
  }

  Future<void> _capture() async {
    try {
      final boundary = _key.currentContext?.findRenderObject();
      if (boundary == null || boundary is! RenderRepaintBoundary) {
        widget.onDone(false, '导出失败：无法获取区域');
        return;
      }
      final image =
          await (boundary as RenderRepaintBoundary).toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        widget.onDone(false, '导出失败：图片数据为空');
        return;
      }
      final file = File(
          '${(await getTemporaryDirectory()).path}/holiday_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      try {
        const ch = MethodChannel('gallery_saver');
        await ch.invokeMethod('saveToGallery', {'filePath': file.path});
        widget.onDone(true, '✅ 已保存到「相册-排班表」文件夹');
      } catch (_) {
        widget.onDone(true, '✅ 图片已保存到临时目录:\n${file.path}');
      }
    } catch (e) {
      widget.onDone(false, '导出失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.schedule;
    final weeks = s.byWeek();
    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: RepaintBoundary(
        key: _key,
        child: Container(
          padding: const EdgeInsets.all(14),
          color: Colors.white,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('假期排班表 - ${s.name}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text('${s.holidayRangeText()} · 每人休假 ${s.targetRestDays} 天',
                    style:
                        TextStyle(fontSize: 13, color: Colors.grey[600])),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: weeks.entries.map((e) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('📍 ${e.key}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: e.value.map((d) {
                              return Container(
                                width: 120,
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: d.isClosed
                                      ? Colors.grey[200]
                                      : Colors.grey[50],
                                  border: Border.all(
                                      color: d.isClosed
                                          ? Colors.grey
                                          : Colors.grey[300]!),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                        '${widget.dayName(d.date.weekday - 1)} ${d.date.month}/${d.date.day}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12)),
                                    const Divider(height: 8),
                                    if (d.isClosed)
                                      const Text('关门',
                                          style: TextStyle(fontSize: 12))
                                    else ...[
                                      Text('99999 ${d.person99999}',
                                          style: const TextStyle(
                                              fontSize: 11)),
                                      Text('协管 ${d.personXieguan}',
                                          style: const TextStyle(
                                              fontSize: 11)),
                                      if (d.personRest.isNotEmpty)
                                        Container(
                                          margin: const EdgeInsets.only(top: 3),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                              color: Colors.orange[100],
                                              borderRadius:
                                                  BorderRadius.circular(6)),
                                          child: Text('休班 ${d.personRest}',
                                              style: const TextStyle(
                                                  fontSize: 10,
                                                  fontWeight:
                                                      FontWeight.bold)),
                                        ),
                                    ],
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                const Text('统计',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ...s.names.map((n) => Text(
                    '$n: 休假${s.restCountOf(n)}天  99999×${s.count99999Of(n)}  协管×${s.countXieguanOf(n)}',
                    style: const TextStyle(fontSize: 12))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
